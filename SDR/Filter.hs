module SDR.Filter where

import Control.Monad
import Control.Monad.Trans.Either
import Data.Bits
import Data.Word
import Data.Array.MArray
import Foreign.Storable
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Foreign.C.Types
import Data.Complex
import Foreign.ForeignPtr
import Foreign.Storable.Complex
import Foreign.Ptr
import Control.Exception 

import Pipes

import SDR.Buffer

data Buffer a = Buffer {
    buffer :: ForeignPtr a,
    offset :: Int,
    size   :: Int
}

newBuffer :: Storable a => Int -> IO (Buffer a)
newBuffer size = do
    buf <- mallocForeignBufferAligned size
    return $ Buffer buf 0 size

advanceOutBuf :: Storable a => Int -> Buffer a -> Int -> Pipe b (ForeignPtr a) IO (Buffer a)
advanceOutBuf blockSizeOut (Buffer bufOut offsetOut spaceOut) count = 
    if count == spaceOut then do
        yield bufOut
        outBuf' <- lift $ mallocForeignBufferAligned blockSizeOut
        return $ Buffer outBuf' 0 blockSizeOut
    else 
        return $ Buffer bufOut (offsetOut + count) (spaceOut - count) 

--Filtering
type FilterSingleC a = CInt -> Ptr a -> CInt -> Ptr a -> Ptr a -> IO ()
type FilterCrossC  a = CInt -> Ptr a -> CInt -> CInt -> Ptr a -> Ptr a -> Ptr a -> IO ()

foreign import ccall unsafe "filter_onebuf_c"
    c_filterOneBufC   :: FilterSingleC (Complex CDouble)

foreign import ccall unsafe "filter_crossbuf_c"
    c_filterCrossBufC :: FilterCrossC (Complex CDouble)

foreign import ccall unsafe "filter_onebuf_r"
    c_filterOneBufR   :: FilterSingleC CDouble

foreign import ccall unsafe "filter_crossbuf_r"
    c_filterCrossBufR :: FilterCrossC CDouble

type FilterSingle a = Int -> ForeignPtr a -> Int -> Int -> ForeignPtr a -> Int -> ForeignPtr a -> IO ()
type FilterCross  a = Int -> ForeignPtr a -> Int -> Int -> Int -> ForeignPtr a -> ForeignPtr a -> Int -> ForeignPtr a -> IO ()

filterOneBuf :: Storable a => FilterSingleC a -> FilterSingle a
filterOneBuf cfunc coeffsLength coeffs num inOffset inBuf outOffset outBuf = 
    withForeignPtr coeffs $ \cp -> 
    withForeignPtr inBuf  $ \ip -> 
    withForeignPtr outBuf $ \op -> 
        cfunc (fromIntegral coeffsLength) 
              cp 
              (fromIntegral num) 
              (advancePtr ip inOffset) 
              (advancePtr op outOffset)

filterCrossBuf :: Storable a => FilterCrossC a -> FilterCross a
filterCrossBuf cfunc coeffsLength coeffs numInput num lastOffset lastBuf nextBuf outOffset outBuf = 
    withForeignPtr coeffs  $ \cp -> 
    withForeignPtr lastBuf $ \lp -> 
    withForeignPtr nextBuf $ \np -> 
    withForeignPtr outBuf  $ \op -> 
        cfunc (fromIntegral coeffsLength) 
              cp 
              (fromIntegral numInput) 
              (fromIntegral num) 
              (advancePtr lp lastOffset) 
              np 
              (advancePtr op outOffset)

filterOneBufC   = filterOneBuf   c_filterOneBufC
filterCrossBufC = filterCrossBuf c_filterCrossBufC
filterOneBufR   = filterOneBuf   c_filterOneBufR
filterCrossBufR = filterCrossBuf c_filterCrossBufR

filterr :: (Storable a) => FilterSingle a -> FilterCross a -> [a] -> Int -> Int -> IO (Pipe (ForeignPtr a) (ForeignPtr a) IO ())
filterr single cross coeffs blockSizeIn blockSizeOut = do
    let numCoeffs = length coeffs
    c <- mallocForeignBufferAligned numCoeffs
    withForeignPtr c $ \cp -> pokeArray cp coeffs
    return $ filter' numCoeffs c 
    where 
    filter' numCoeffs coeffs = do
        inBuf  <- await
        outBuf <- lift $ newBuffer blockSizeOut
        simple (Buffer inBuf 0 blockSizeIn) outBuf 

        where

        simple (Buffer bufIn offsetIn spaceIn) bufferOut@(Buffer bufOut offsetOut spaceOut) = do
            let count = min (spaceIn - numCoeffs + 1) spaceOut
            lift $ single numCoeffs coeffs count offsetIn bufIn offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            let spaceIn'  = spaceIn - count
                offsetIn' = offsetIn + count

            case spaceIn' < numCoeffs of
                False -> simple (Buffer bufIn offsetIn' spaceIn') bufferOut'
                True  -> do
                    next <- await
                    crossover (Buffer bufIn offsetIn' spaceIn') next bufferOut'

        crossover (Buffer bufLast offsetLast spaceLast) bufNext bufferOut@(Buffer bufOut offsetOut spaceOut) = do
            let count = min (spaceLast - 1) spaceOut
            lift $ cross numCoeffs coeffs spaceLast count offsetLast bufLast bufNext offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            case spaceLast - 1 == count of 
                True  -> simple (Buffer bufNext 0 blockSizeIn) bufferOut'
                False -> crossover (Buffer bufLast (offsetLast + count) (spaceLast - count)) bufNext bufferOut'

filterC = filterr filterOneBufC filterCrossBufC
filterR = filterr filterOneBufR filterCrossBufR

--Decimation
type DecimateSingleC a = CInt -> CInt -> Ptr a -> CInt -> Ptr a -> Ptr a -> IO ()
type DecimateCrossC  a = CInt -> CInt -> Ptr a -> CInt -> CInt -> Ptr a -> Ptr a -> Ptr a -> IO ()

foreign import ccall unsafe "decimate_onebuf_c"
    c_decimateOneBufC   :: DecimateSingleC (Complex CDouble)

foreign import ccall unsafe "decimate_crossbuf_c"
    c_decimateCrossBufC :: DecimateCrossC (Complex CDouble)

foreign import ccall unsafe "decimate_onebuf_r"
    c_decimateOneBufR   :: DecimateSingleC CDouble

foreign import ccall unsafe "decimate_crossbuf_r"
    c_decimateCrossBufR :: DecimateCrossC CDouble

type DecimateSingle a = Int -> Int -> ForeignPtr a -> Int -> Int -> ForeignPtr a -> Int -> ForeignPtr a -> IO ()
type DecimateCross  a = Int -> Int -> ForeignPtr a -> Int -> Int -> Int -> ForeignPtr a -> ForeignPtr a -> Int -> ForeignPtr a -> IO ()

decimateOneBuf :: Storable a => DecimateSingleC a -> DecimateSingle a
decimateOneBuf cfunc factor coeffsLength coeffs num inOffset inBuf outOffset outBuf = 
    withForeignPtr coeffs $ \cp -> 
    withForeignPtr inBuf  $ \ip -> 
    withForeignPtr outBuf $ \op -> 
        cfunc (fromIntegral factor) 
              (fromIntegral coeffsLength) 
              cp 
              (fromIntegral num) 
              (advancePtr ip inOffset) 
              (advancePtr op outOffset)

decimateCrossBuf :: Storable a => DecimateCrossC a -> DecimateCross a
decimateCrossBuf cfunc factor coeffsLength coeffs numInput num lastOffset lastBuf nextBuf outOffset outBuf = 
    withForeignPtr coeffs  $ \cp -> 
    withForeignPtr lastBuf $ \lp -> 
    withForeignPtr nextBuf $ \np -> 
    withForeignPtr outBuf  $ \op -> 
        cfunc (fromIntegral factor) 
              (fromIntegral coeffsLength) 
              cp 
              (fromIntegral numInput) 
              (fromIntegral num) 
              (advancePtr lp lastOffset) 
              np 
              (advancePtr op outOffset)

decimateOneBufC   = decimateOneBuf   c_decimateOneBufC
decimateCrossBufC = decimateCrossBuf c_decimateCrossBufC
decimateOneBufR   = decimateOneBuf   c_decimateOneBufR
decimateCrossBufR = decimateCrossBuf c_decimateCrossBufR

decimate :: (Storable a) => DecimateSingle a -> DecimateCross a -> Int -> [a] -> Int -> Int -> IO (Pipe (ForeignPtr a) (ForeignPtr a) IO ())
decimate single cross factor coeffs blockSizeIn blockSizeOut = do
    let numCoeffs = length coeffs
    c <- mallocForeignBufferAligned numCoeffs
    withForeignPtr c $ \cp -> pokeArray cp coeffs
    return $ decimate' numCoeffs c 
    where
    decimate' numCoeffs coeffs = do
        inBuf  <- await
        outBuf <- lift $ newBuffer blockSizeOut
        simple (Buffer inBuf 0 blockSizeIn) outBuf

        where

        simple (Buffer bufIn offsetIn spaceIn) bufferOut@(Buffer bufOut offsetOut spaceOut) = do

            assert (spaceIn >= numCoeffs) $ return ()

            let count = min (((spaceIn - numCoeffs) `quot` factor) + 1) spaceOut
            lift $ single factor numCoeffs coeffs count offsetIn bufIn offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            let spaceIn'  = spaceIn - count * factor
                offsetIn' = offsetIn + count * factor

            case spaceIn' < numCoeffs of
                False -> simple (Buffer bufIn offsetIn' spaceIn') bufferOut'
                True  -> do
                    next <- await
                    crossover (Buffer bufIn offsetIn' spaceIn') next bufferOut'

        crossover (Buffer bufLast offsetLast spaceLast) bufNext bufferOut@(Buffer bufOut offsetOut spaceOut) = do

            assert (spaceLast < numCoeffs) $ return ()

            let count = min (((spaceLast - 1) `quot` factor) + 1) spaceOut
            lift $ cross factor numCoeffs coeffs spaceLast count offsetLast bufLast bufNext offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            case ((spaceLast - 1) `quot` factor) + 1 == count of 
                True  -> simple (Buffer bufNext (offsetLast + count * factor - blockSizeIn) (blockSizeIn - (offsetLast + count * factor - blockSizeIn))) bufferOut'
                False -> crossover (Buffer bufLast (offsetLast + count * factor) (spaceLast - count * factor)) bufNext bufferOut'

decimateC = decimate decimateOneBufC decimateCrossBufC
decimateR = decimate decimateOneBufR decimateCrossBufR

--Rational resampling
type ResampleSingleC a = CInt -> CInt -> CInt -> Ptr a -> CInt -> CInt -> Ptr a -> Ptr a -> IO CInt
type ResampleCrossC  a = CInt -> CInt -> CInt -> Ptr a -> CInt -> CInt -> CInt -> Ptr a -> Ptr a -> Ptr a -> IO CInt

foreign import ccall unsafe "resample_onebuf_c"
    c_resampleOneBufC   :: ResampleSingleC (Complex CDouble)

foreign import ccall unsafe "resample_crossbuf_c"
    c_resampleCrossBufC :: ResampleCrossC (Complex CDouble)

foreign import ccall unsafe "resample_onebuf_r"
    c_resampleOneBufR   :: ResampleSingleC CDouble

foreign import ccall unsafe "resample_crossbuf_r"
    c_resampleCrossBufR :: ResampleCrossC CDouble

type ResampleSingle a = Int -> Int -> Int -> ForeignPtr a -> Int -> Int -> Int -> ForeignPtr a -> Int -> ForeignPtr a -> IO Int
type ResampleCross  a = Int -> Int -> Int -> ForeignPtr a -> Int -> Int -> Int -> Int -> ForeignPtr a -> ForeignPtr a -> Int -> ForeignPtr a -> IO Int

resampleOneBuf :: Storable a => ResampleSingleC a -> ResampleSingle a
resampleOneBuf cfunc interpolation decimation coeffsLength coeffs filterOffset count inOffset inBuf outOffset outBuf = liftM fromIntegral $ 
    withForeignPtr coeffs $ \cp -> 
    withForeignPtr inBuf  $ \ip -> 
    withForeignPtr outBuf $ \op -> 
        cfunc (fromIntegral interpolation) 
              (fromIntegral decimation) 
              (fromIntegral coeffsLength) 
              cp 
              (fromIntegral filterOffset) 
              (fromIntegral count) 
              (advancePtr ip inOffset)
              (advancePtr op outOffset)

resampleCrossBuf :: Storable a => ResampleCrossC a -> ResampleCross a
resampleCrossBuf cfunc interpolation decimation coeffsLength coeffs filterOffset numInput count lastOffset lastBuf nextBuf outOffset outBuf = liftM fromIntegral $ 
    withForeignPtr coeffs  $ \cp -> 
    withForeignPtr lastBuf $ \lp -> 
    withForeignPtr nextBuf $ \np -> 
    withForeignPtr outBuf  $ \op -> 
        cfunc (fromIntegral interpolation) 
              (fromIntegral decimation) 
              (fromIntegral coeffsLength) 
              cp 
              (fromIntegral filterOffset) 
              (fromIntegral numInput) 
              (fromIntegral count) 
              (advancePtr lp lastOffset)
              np 
              (advancePtr op outOffset)

resampleOneBufC   = resampleOneBuf   c_resampleOneBufC
resampleCrossBufC = resampleCrossBuf c_resampleCrossBufC
resampleOneBufR   = resampleOneBuf   c_resampleOneBufR
resampleCrossBufR = resampleCrossBuf c_resampleCrossBufR

quotUp q d = (q + (d - 1)) `quot` d

resample :: (Storable a) => ResampleSingle a -> ResampleCross a -> Int -> Int -> [a] -> Int -> Int -> IO (Pipe (ForeignPtr a) (ForeignPtr a) IO ())
resample single cross interpolation decimation coeffs blockSizeIn blockSizeOut = do
    let numCoeffs = length coeffs
    c <- mallocForeignBufferAligned numCoeffs
    withForeignPtr c $ \cp -> pokeArray cp coeffs
    return $ resample' numCoeffs c 
    where
    resample' numCoeffs coeffs = do
        inBuf  <- await
        outBuf <- lift $ newBuffer blockSizeOut
        simple (Buffer inBuf 0 blockSizeIn) outBuf 0

        where

        simple (Buffer bufIn offsetIn spaceIn) bufferOut@(Buffer bufOut offsetOut spaceOut) filterOffset = do
            --Check consistency
            assert (spaceIn * interpolation >= numCoeffs - filterOffset) $ return ()
            assert (offsetIn + spaceIn == blockSizeIn) $ return ()
            --available number of samples == interpolation * num_input
            --required number of samples  == decimation * (num_output - 1) + filter_length - filter_offset
            let count = min (((spaceIn * interpolation - numCoeffs + filterOffset) `quot` decimation) + 1) spaceOut
            --Run filter
            endOffset <- lift $ single interpolation decimation numCoeffs coeffs filterOffset count offsetIn bufIn offsetOut bufOut
            --Check consistency
            assert ((count * decimation + endOffset - filterOffset) `rem` interpolation == 0) $ return ()
            --Advance the output buffer
            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count
            --samples no longer needed starting from filterOffset == count * decimation - filterOffset
            --inputs lying in this region                         == (count * decimation - filterOffset) / interpolation (rounding up)
            let usedInput = (count * decimation - filterOffset) `quotUp` interpolation 
                spaceIn'  = spaceIn  - usedInput
                offsetIn' = offsetIn + usedInput

            case spaceIn' * interpolation < numCoeffs - endOffset of
                False -> do
                    simple (Buffer bufIn offsetIn' spaceIn') bufferOut' endOffset
                True  -> do
                    next <- await
                    case spaceIn' == 0 of
                        True ->  simple    (Buffer next 0 blockSizeIn) bufferOut' endOffset
                        False -> crossover (Buffer bufIn offsetIn' spaceIn') next bufferOut' endOffset

        crossover (Buffer bufLast offsetLast spaceLast) bufNext bufferOut@(Buffer bufOut offsetOut spaceOut) filterOffset = do
            --Check conssitency
            assert (spaceLast > 0) $ return ()
            assert (spaceLast * interpolation < numCoeffs - filterOffset) $ return ()
            assert (offsetLast + spaceLast == blockSizeIn) $ return ()
            --outputsComputable is the number of outputs that need to be computed for the last buffer to no longer be needed
            --outputsComputable * decimation == numInput * interpolation + filterOffset + k
            let outputsComputable = (spaceLast * interpolation + filterOffset) `quotUp` decimation
                count = min outputsComputable spaceOut
            assert (count /= 0) $ return ()
            --Run the filter
            endOffset <- lift $ cross interpolation decimation numCoeffs coeffs filterOffset spaceLast count offsetLast bufLast bufNext offsetOut bufOut
            --Check consistency
            assert ((count * decimation + endOffset - filterOffset) `rem` interpolation == 0) $ return ()
            --Advance the output buffer
            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            let inputUsed = (count * decimation - filterOffset) `quotUp` interpolation

            case inputUsed >= spaceLast of 
                True  -> simple (Buffer bufNext (offsetLast + inputUsed - blockSizeIn) (2 * blockSizeIn - (offsetLast + inputUsed))) bufferOut' endOffset
                False -> crossover (Buffer bufLast (offsetLast + inputUsed) (spaceLast - inputUsed)) bufNext bufferOut' endOffset

resampleC = resample resampleOneBufC resampleCrossBufC
resampleR = resample resampleOneBufR resampleCrossBufR

