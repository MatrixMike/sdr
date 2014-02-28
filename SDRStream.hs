{-# LANGUAGE GADTs #-}
module SDRStream where

import Control.Monad
import Control.Monad.Trans.Either
import Data.Bits
import Data.Word

import Data.Array.MArray
import Foreign.Storable
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Data.Array.Storable
import Foreign.C.Types
import Data.Array.CArray
import Data.Array.CArray.Base
import Data.Complex
import Foreign.ForeignPtr
import Foreign.Storable.Complex
import Foreign.Ptr

import Pipes

import RTLSDR
import HFFT
import SimpleLine

--RTLSDR streaming
sdrStream :: Word32 -> Word32 -> Int -> EitherT String IO (Producer (StorableArray Int CUChar) IO ())
sdrStream frequency sampleRate samples = do
    lift $ putStrLn "Initializing RTLSDR device"

    dev' <- lift $ open 0
    dev  <- maybe (left "Failed to open device") return dev'

    lift $ do
        t <- getTunerType dev
        putStrLn $ "Found a: " ++ show t

        setFreqCorrection dev 0
        setSampleRate dev sampleRate
        setCenterFreq dev frequency
        setTunerGainMode dev False

        resetBuffer dev

        return $ mkSdrStream samples dev

mkSdrStream :: Int -> RTLSDR -> Producer (StorableArray Int CUChar) IO ()
mkSdrStream samples dev = do
    res' <- lift $ readSync dev (samples * 2)
    maybe (lift $ print "Stream terminated") (yield >=> const (mkSdrStream samples dev)) res'

--Output dumping
printStream :: (Show e, Storable e, m ~ IO, MArray a e m, Ix i) => Consumer (a i e) m ()
printStream = forever $ do
    res <- await 
    res <- lift $ getElems res
    lift $ print res

devnull :: (Show e, Storable e, m ~ IO, MArray a e m, Ix i) => Consumer (a i e) m ()
devnull = forever await

--Conversion of sample bytes to doubles
foreign import ccall unsafe "convertArray"
    c_convertArray :: CInt -> Ptr CUChar -> Ptr (Complex CDouble) -> IO ()

makeComplexBuffer :: Int -> StorableArray Int CUChar -> IO (StorableArray Int (Complex CDouble))
makeComplexBuffer samples ina = do
    oArray <- newArray_ (0, samples - 1) 
    withStorableArray oArray $ \op -> 
        withStorableArray ina $ \inp -> do
            c_convertArray (fromIntegral samples * 2) inp op
            return oArray

--FFT
mkFFTWArray :: Int -> IO (IOCArray Int (Complex CDouble))
mkFFTWArray samples = do
    memory <- fftwMalloc (fromIntegral $ samples * sizeOf (undefined :: Complex CDouble))
    fp <- newForeignPtr_ memory
    unsafeForeignPtrToIOCArray fp (0, samples - 1) :: IO (IOCArray Int (Complex CDouble))

foreign import ccall unsafe "convertFFT"
    c_convertFFT :: CInt -> Ptr (Complex CDouble) -> Ptr (Complex CDouble) -> IO ()

convertFFT :: Int -> StorableArray Int (Complex CDouble) -> IOCArray Int (Complex CDouble) -> IO ()
convertFFT samples ina out = 
    withStorableArray ina $ \ip -> 
    withIOCArray      out $ \op -> 
        c_convertFFT (fromIntegral samples) ip op

convertForFFT :: Int -> IOCArray Int (Complex CDouble) -> Pipe (StorableArray Int (Complex CDouble)) (IOCArray Int (Complex CDouble)) IO ()
convertForFFT samples out = forever $ do
    res <- await
    lift $ convertFFT samples res out
    yield out

fftw :: Int -> IOCArray Int (Complex CDouble) -> IO (Pipe (StorableArray Int (Complex CDouble)) (IOCArray Int (Complex CDouble)) IO ())
fftw samples array = do
    plan <- withIOCArray array $ \ptr -> 
        planDFT1d samples ptr ptr (-1) (1 `shiftL` 6)
    
    return $ forever $ do
        res <- await
        lift $ convertFFT samples res array
        lift $ execute plan
        yield array

mkFFTWArrayReal :: Int -> IO (IOCArray Int CDouble)
mkFFTWArrayReal samples = do
    memory <- fftwMalloc (fromIntegral $ samples * sizeOf (undefined :: CDouble))
    fp <- newForeignPtr_ memory
    unsafeForeignPtrToIOCArray fp (0, samples - 1) :: IO (IOCArray Int CDouble)

fftwReal :: Int -> IOCArray Int CDouble -> IOCArray Int (Complex CDouble) -> IO (Pipe (StorableArray Int CDouble) (IOCArray Int (Complex CDouble)) IO ())
fftwReal samples ina out = do
    plan <- withIOCArray ina $ \ip -> 
        withIOCArray out $ \op -> 
            planDFTR2C1d samples ip op (1 `shiftL` 6)

    return $ forever $ do
        res <- await
        lift $ withStorableArray res $ \ip -> 
            withIOCArray ina $ \op -> 
                moveBytes op ip (samples * sizeOf (undefined :: CDouble))
        lift $ execute plan
        yield out

--Spectrum analyser plots
plot :: Int -> CFloat -> EitherT String IO (Consumer (IOCArray Int (Complex CDouble)) IO ())
plot samples gain = do
    graphFunc <- graph
    let xCoords = take samples $ iterate (+ (2 / fromIntegral samples)) (-1)
    return $ forever $ do
        dat <- await
        e <- lift $ getElems dat
        let mags = map ((* gain) . realToFrac . magnitude) e
        let interleave = concatMap (\(x, y) -> [x, y])
        lift $ graphFunc $ interleave $ zip xCoords mags

--Filtering
firFilter :: Int -> [Complex CDouble] -> IO (Pipe (StorableArray Int (Complex CDouble)) (StorableArray Int (Complex CDouble)) IO ())
firFilter samples coeffs = do
    c <- newListArray (0, length coeffs - 1) coeffs
    return $ do
        first <- await
        let loop last = do
            this <- await
            out <- lift $ doFilter (length coeffs) c samples last this 
            yield out
            loop this
        loop first

foreign import ccall unsafe "filter"
    c_filter :: CInt -> Ptr (Complex CDouble) -> CInt -> Ptr (Complex CDouble) -> Ptr (Complex CDouble ) -> Ptr (Complex CDouble) -> IO ()

doFilter :: Int -> StorableArray Int (Complex CDouble) -> Int -> StorableArray Int (Complex CDouble) -> StorableArray Int (Complex CDouble) -> IO (StorableArray Int (Complex CDouble))
doFilter coeffsLength coeffs samples lastBuffer thisBuffer = do
    outBuffer <- newArray_ (0, samples - 1)
    withStorableArray coeffs     $ \cp -> 
        withStorableArray lastBuffer $ \lp -> 
        withStorableArray thisBuffer $ \tp -> 
        withStorableArray outBuffer  $ \op -> 
            c_filter (fromIntegral coeffsLength) cp (fromIntegral samples) lp tp op
    return outBuffer
   
--Decimation
decimate :: Int -> Int -> [Complex CDouble] -> IO (Pipe (StorableArray Int (Complex CDouble)) (StorableArray Int (Complex CDouble)) IO ())
decimate factor samples coeffs = do
    c <- newListArray (0, length coeffs - 1) coeffs
    return $ do
        first <- await
        let loop last = do
            this <- await
            out <- lift $ doDecimation factor (length coeffs) c samples last this 
            yield out
            loop this
        loop first

foreign import ccall unsafe "decimate"
    c_decimate :: CInt -> CInt -> Ptr (Complex CDouble) -> CInt -> Ptr (Complex CDouble) -> Ptr (Complex CDouble ) -> Ptr (Complex CDouble) -> IO ()

doDecimation :: Int -> Int -> StorableArray Int (Complex CDouble) -> Int -> StorableArray Int (Complex CDouble) -> StorableArray Int (Complex CDouble) -> IO (StorableArray Int (Complex CDouble))
doDecimation factor coeffsLength coeffs samples lastBuffer thisBuffer = do
    outBuffer <- newArray_ (0, (samples `quot` factor) - 1)
    withStorableArray coeffs     $ \cp -> 
        withStorableArray lastBuffer $ \lp -> 
        withStorableArray thisBuffer $ \tp -> 
        withStorableArray outBuffer  $ \op -> 
            c_decimate (fromIntegral factor) (fromIntegral coeffsLength) cp (fromIntegral samples) lp tp op
    return outBuffer

--Demodulation
foreign import ccall unsafe "fmDemod"
    c_fmDemod :: CInt -> Ptr (Complex CDouble) -> Ptr (Complex CDouble) -> Ptr CDouble -> IO ()

fmDemod :: Int -> StorableArray Int (Complex CDouble) -> IO (StorableArray Int CDouble)
fmDemod samples ina = do
    out <- newArray_ (0, samples - 1)
    withStorableArray ina $ \ip -> 
        withStorableArray out $ \op -> 
        alloca $ \sp -> do
            poke sp (fromIntegral 0)
            c_fmDemod (fromIntegral samples) sp ip op
    return out

