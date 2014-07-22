{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}
module SDR.Filter where

import Foreign.C.Types
import Data.Complex
import Control.Exception 
import qualified Data.Vector.Generic          as VG
import qualified Data.Vector.Generic.Mutable  as VGM
import qualified Data.Vector.Storable         as VS
import qualified Data.Vector.Storable.Mutable as VSM
import Control.Monad.Primitive

import Pipes

import SDR.Util

class Mult a b where
    mult :: a -> b -> a

instance (Num a) => Mult a a where
    mult = (*)

instance (Num a) => Mult (Complex a) a where
    mult (x :+ y) z = (x * z) :+ (y * z)

data Buffer v a = Buffer {
    buffer :: v a,
    offset :: Int,
    size   :: Int
}

newBuffer :: (PrimMonad m, VGM.MVector vm a) => Int -> m (Buffer (vm (PrimState m)) a)
newBuffer size = do
    buf <- VGM.new size
    return $ Buffer buf 0 size

advanceOutBuf :: (PrimMonad m, VG.Vector v a) => Int -> Buffer (VG.Mutable v (PrimState m)) a -> Int -> Pipe b (v a) m (Buffer (VG.Mutable v (PrimState m)) a)
advanceOutBuf blockSizeOut (Buffer bufOut offsetOut spaceOut) count = 
    if count == spaceOut then do
        bufOutF <- lift $ VG.unsafeFreeze bufOut
        yield bufOutF
        outBuf' <- lift $ VGM.new blockSizeOut
        return $ Buffer outBuf' 0 blockSizeOut
    else 
        return $ Buffer bufOut (offsetOut + count) (spaceOut - count) 

--Filtering
{-# INLINE filterOne #-}
filterOne :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => v b -> Int -> v a -> Int -> vm (PrimState m) a -> m ()
filterOne coeffs num inBuf outOffset outBuf = fill 0
    where
    fill i 
        | i < num = do
            let dp = dotProd i
            VGM.unsafeWrite outBuf (i + outOffset) dp
            fill (i + 1)
        | otherwise = return ()
    {-# INLINE dotProd #-}
    dotProd offset = VG.sum $ VG.zipWith mult (VG.unsafeDrop offset inBuf) coeffs

{-# INLINE filterCross #-}
filterCross :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => v b -> Int -> v a -> v a -> Int -> vm (PrimState m) a -> m ()
filterCross coeffs num lastBuf nextBuf outOffset outBuf = fill 0
    where
    fill i 
        | i < num = do
            let dp = dotProd i
            VGM.unsafeWrite outBuf (i + outOffset) dp
            fill (i + 1)
        | otherwise  = return ()
    {-# INLINE dotProd #-}
    dotProd i = VG.sum $ VG.zipWith mult (VG.unsafeDrop i lastBuf VG.++ nextBuf) coeffs

{-# SPECIALIZE INLINE filterr :: VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector CDouble) (VS.Vector CDouble) IO () #-}
{-# SPECIALIZE INLINE filterr :: VS.Vector (Complex CDouble) -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
{-# SPECIALIZE INLINE filterr :: VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
filterr :: (PrimMonad m, VG.Vector v a, VG.Vector v b, Num a, Mult a b) => v b -> Int -> Int -> Pipe (v a) (v a) m ()
filterr coeffs blockSizeIn blockSizeOut = filter' (VG.length coeffs) coeffs
    where 
    filter' numCoeffs coeffs = do
        inBuf  <- await
        outBuf <- lift $ newBuffer blockSizeOut
        simple (Buffer inBuf 0 blockSizeIn) outBuf 

        where

        simple (Buffer bufIn offsetIn spaceIn) bufferOut@(Buffer bufOut offsetOut spaceOut) = do
            let count = min (spaceIn - numCoeffs + 1) spaceOut
            lift $ filterOne coeffs count (VG.unsafeDrop offsetIn bufIn) offsetOut bufOut

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
            lift $ filterCross coeffs count (VG.unsafeDrop offsetLast bufLast) bufNext offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            case spaceLast - 1 == count of 
                True  -> simple (Buffer bufNext 0 blockSizeIn) bufferOut'
                False -> crossover (Buffer bufLast (offsetLast + count) (spaceLast - count)) bufNext bufferOut'

--Decimation
{-# INLINE decimateOne #-}
decimateOne :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => Int -> v b -> Int -> v a -> Int -> vm (PrimState m) a -> m ()
decimateOne factor coeffs num inBuf outOffset outBuf = fill 0 0
    where 
    fill i j
        | i < num = do
            let dp = dotProd j
            VGM.unsafeWrite outBuf (i + outOffset) dp
            fill (i + 1) (j + factor)
        | otherwise = return ()
    {-# INLINE dotProd #-}
    dotProd offset = VG.sum $ VG.zipWith mult (VG.unsafeDrop offset inBuf) coeffs

{-# INLINE decimateCross #-}
decimateCross :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => Int -> v b -> Int -> v a -> v a -> Int -> vm (PrimState m) a -> m ()
decimateCross factor coeffs num lastBuf nextBuf outOffset outBuf = fill 0 0
    where
    fill i j
        | i < num = do
            let dp = dotProd j
            VGM.unsafeWrite outBuf (i + outOffset) dp
            fill (i + 1) (j + factor)
        | otherwise  = return ()
    {-# INLINE dotProd #-}
    dotProd i = VG.sum $ VG.zipWith mult (VG.unsafeDrop i lastBuf VG.++ nextBuf) coeffs

{-# SPECIALIZE INLINE decimate :: Int -> VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector CDouble) (VS.Vector CDouble) IO () #-}
{-# SPECIALIZE INLINE decimate :: Int -> VS.Vector (Complex CDouble) -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
{-# SPECIALIZE INLINE decimate :: Int -> VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
decimate :: (PrimMonad m, VG.Vector v a, VG.Vector v b, Mult a b, Num a) => Int -> v b -> Int -> Int -> Pipe (v a) (v a) m ()
decimate factor coeffs blockSizeIn blockSizeOut = decimate' (VG.length coeffs) coeffs
    where
    decimate' numCoeffs coeffs = do
        inBuf  <- await
        outBuf <- lift $ newBuffer blockSizeOut
        simple (Buffer inBuf 0 blockSizeIn) outBuf

        where

        simple (Buffer bufIn offsetIn spaceIn) bufferOut@(Buffer bufOut offsetOut spaceOut) = do

            assert (spaceIn >= numCoeffs) $ return ()

            let count = min (((spaceIn - numCoeffs) `quot` factor) + 1) spaceOut
            lift $ decimateOne factor coeffs count (VG.unsafeDrop offsetIn bufIn) offsetOut bufOut

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
            lift $ decimateCross factor coeffs count (VG.unsafeDrop offsetLast bufLast) bufNext offsetOut bufOut

            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            case ((spaceLast - 1) `quot` factor) + 1 == count of 
                True  -> simple (Buffer bufNext (offsetLast + count * factor - blockSizeIn) (blockSizeIn - (offsetLast + count * factor - blockSizeIn))) bufferOut'
                False -> crossover (Buffer bufLast (offsetLast + count * factor) (spaceLast - count * factor)) bufNext bufferOut'

--Rational resampling
{-# INLINE resampleOne #-}
resampleOne :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => Int -> Int -> v b -> Int -> Int -> v a -> Int -> vm (PrimState m) a -> m Int
resampleOne interpolation decimation coeffs filterOffset count inBuf outOffset outBuf = fill 0 filterOffset 0
    where
    fill i filterOffset inputOffset
        | i < count = do
            let dp = dotProd inputOffset
            VGM.unsafeWrite outBuf (i + outOffset) dp
            let (q, r)        = quotRem (decimation - filterOffset - 1) interpolation
                inputOffset'  = inputOffset + q + 1
                filterOffset' = interpolation - 1 - r
            filterOffset' `seq` inputOffset' `seq` fill (i + 1) filterOffset' inputOffset'
        | otherwise = return filterOffset
    {-# INLINE dotProd #-}
    dotProd offset = VG.sum $ VG.zipWith mult (VG.unsafeDrop offset inBuf) (stride interpolation coeffs)

{-# INLINE resampleCross #-}
resampleCross :: (PrimMonad m, Num a, Mult a b, VG.Vector v a, VG.Vector v b, VGM.MVector vm a) => Int -> Int -> v b -> Int -> Int -> v a -> v a -> Int -> vm (PrimState m) a -> m Int
resampleCross interpolation decimation coeffs filterOffset count lastBuf nextBuf outOffset outBuf = fill 0 filterOffset 0
    where
    fill i filterOffset inputOffset
        | i < count = do
            let dp = dotProd inputOffset
            VGM.unsafeWrite outBuf (i + outOffset) dp
            let (q, r)        = quotRem (decimation - filterOffset - 1) interpolation
                inputOffset'  = inputOffset + q + 1
                filterOffset' = interpolation - 1 - r
            filterOffset' `seq` inputOffset' `seq` fill (i + 1) filterOffset' inputOffset'
        | otherwise = return filterOffset
    {-# INLINE dotProd #-}
    dotProd i = VG.sum $ VG.zipWith mult (VG.unsafeDrop i lastBuf VG.++ nextBuf) (stride interpolation coeffs)

quotUp q d = (q + (d - 1)) `quot` d

{-# SPECIALIZE INLINE resample :: Int -> Int -> VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector CDouble) (VS.Vector CDouble) IO () #-}
{-# SPECIALIZE INLINE resample :: Int -> Int -> VS.Vector (Complex CDouble) -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
{-# SPECIALIZE INLINE resample :: Int -> Int -> VS.Vector CDouble -> Int -> Int -> Pipe (VS.Vector (Complex CDouble)) (VS.Vector (Complex CDouble)) IO () #-}
resample :: (PrimMonad m, VG.Vector v a, VG.Vector v b, Mult a b, Num a) => Int -> Int -> v b -> Int -> Int -> Pipe (v a) (v a) m ()
resample interpolation decimation coeffs blockSizeIn blockSizeOut = resample' (VG.length coeffs) coeffs
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
            endOffset <- lift $ resampleOne interpolation decimation coeffs filterOffset count (VG.unsafeDrop offsetIn bufIn) offsetOut bufOut
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
            endOffset <- lift $ resampleCross interpolation decimation coeffs filterOffset count (VG.unsafeDrop offsetLast bufLast) bufNext offsetOut bufOut
            --Check consistency
            assert ((count * decimation + endOffset - filterOffset) `rem` interpolation == 0) $ return ()
            --Advance the output buffer
            bufferOut' <- advanceOutBuf blockSizeOut bufferOut count

            let inputUsed = (count * decimation - filterOffset) `quotUp` interpolation

            case inputUsed >= spaceLast of 
                True  -> simple (Buffer bufNext (offsetLast + inputUsed - blockSizeIn) (2 * blockSizeIn - (offsetLast + inputUsed))) bufferOut' endOffset
                False -> crossover (Buffer bufLast (offsetLast + inputUsed) (spaceLast - inputUsed)) bufNext bufferOut' endOffset

