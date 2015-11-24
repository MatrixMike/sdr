{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, MultiParamTypeClasses, FlexibleInstances #-}

{-| Various utiliy signal processing functions -}
module SDR.Util (
    -- * Classes
    Mult,
    mult,

    -- * Conversion to Floating Point
    interleavedIQUnsigned256ToFloat,
    interleavedIQUnsignedByteToFloat,
    interleavedIQUnsignedByteToFloatSSE,
    interleavedIQUnsignedByteToFloatAVX,
    interleavedIQUnsignedByteToFloatFast,
    interleavedIQSigned2048ToFloat,

    -- * Scaling
    scaleC,
    scaleCSSE,
    scaleCAVX,
    scaleFast,

    -- * Misc Utils
    cplxMap,
    quarterBandUp
    ) where

import           Foreign.C.Types
import           Data.Complex
import           Data.Vector.Generic          as VG   hiding ((++))
import qualified Data.Vector.Generic.Mutable  as VGM
import           Data.Vector.Storable         as VS   hiding ((++))
import           Data.Vector.Storable.Mutable as VSM  
import           Control.Monad.Primitive
import           Unsafe.Coerce
import           Foreign.Ptr
import           System.IO.Unsafe
import           Foreign.Storable.Complex

import           SDR.CPUID

-- | A class for things that can be multiplied by a scalar.
class Mult a b where
    mult :: a -> b -> a

instance (Num a) => Mult a a where
    mult = (*)

instance (Num a) => Mult (Complex a) a where
    mult (x :+ y) z = (x * z) :+ (y * z)

-- | Create a vector of complex floating samples from a vector of interleaved I Q components. Each input element ranges from 0 to 255. This is the format that RTLSDR devices use.
{-# INLINE interleavedIQUnsigned256ToFloat #-}
interleavedIQUnsigned256ToFloat :: (Num a, Integral a, Num b, Fractional b, VG.Vector v1 a, VG.Vector v2 (Complex b)) => v1 a -> v2 (Complex b)
interleavedIQUnsigned256ToFloat input = VG.generate (VG.length input `quot` 2) convert
    where
    {-# INLINE convert #-}
    convert idx  = convert' (input `VG.unsafeIndex` (2 * idx)) :+ convert' (input `VG.unsafeIndex` (2 * idx + 1))
    {-# INLINE convert' #-}
    convert' val = (fromIntegral val - 128) / 128

foreign import ccall unsafe "convertC"
    convertC_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloat :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloat inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertC_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCSSE"
    convertCSSE_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using SSE intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatSSE :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatSSE inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCSSE_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCAVX"
    convertCAVX_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using AVX intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatAVX :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatAVX inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCAVX_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

-- | Same as `interleavedIQUnsigned256ToFloat` but uses the fastest SIMD instruction set your processor supports and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatFast :: CPUInfo -> VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatFast info = featureSelect info interleavedIQUnsignedByteToFloat [(hasAVX2, interleavedIQUnsignedByteToFloatAVX), (hasSSE42, interleavedIQUnsignedByteToFloatSSE)]

-- | Create a vector of complex float samples from a vector of interleaved I Q components. Each input element ranges from -2048 to 2047. This is the format that the BladeRF uses.
{-# INLINE interleavedIQSigned2048ToFloat #-}
interleavedIQSigned2048ToFloat :: (Num a, Integral a, Num b, Fractional b, VG.Vector v1 a, VG.Vector v2 (Complex b)) => v1 a -> v2 (Complex b)
interleavedIQSigned2048ToFloat input = VG.generate (VG.length input `quot` 2) convert
    where
    {-# INLINE convert #-}
    convert idx  = convert' (input `VG.unsafeIndex` (2 * idx)) :+ convert' (input `VG.unsafeIndex` (2 * idx + 1))
    {-# INLINE convert' #-}
    convert' val = fromIntegral val / 2048

-- | Scaling
foreign import ccall unsafe "scale"
    scale_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

-- | Scale a vector, written in C
scaleC :: Float                      -- ^ Scale factor
       -> VS.Vector Float            -- ^ Input vector
       -> VS.MVector RealWorld Float -- ^ Output vector
       -> IO ()
scaleC factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scale_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleSSE"
    scaleSSE_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat-> IO ()

-- | Scale a vector, written in C using SSE intrinsics
scaleCSSE :: Float                      -- ^ Scale factor
          -> VS.Vector Float            -- ^ Input vector
          -> VS.MVector RealWorld Float -- ^ Output vector
          -> IO ()
scaleCSSE factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleSSE_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleAVX"
    scaleAVX_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

-- | Scale a vector, written in C using AVX intrinsics
scaleCAVX :: Float                      -- ^ Scale factor
          -> VS.Vector Float            -- ^ Input vector
          -> VS.MVector RealWorld Float -- ^ Output vector
          -> IO ()
scaleCAVX factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleAVX_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

-- | Scale a vector. Uses the fastest SIMD instruction set your processor supports.
scaleFast :: CPUInfo -> Float -> VS.Vector Float -> VS.MVector RealWorld Float -> IO ()
scaleFast info = featureSelect info scaleC [(hasAVX, scaleCAVX), (hasSSE42, scaleCSSE)]

-- | Apply a function to both parts of a complex number
cplxMap :: (a -> b)  -- ^ The function
        -> Complex a -- ^ Input complex number
        -> Complex b -- ^ Output complex number
cplxMap f (x :+ y) = f x :+ f y

-- | Multiplication by this vector shifts all frequencies up by 1/4 of the sampling frequency
quarterBandUp :: (VG.Vector v (Complex n), Num n) 
              => Int -- ^ The length of the Vector
              -> v (Complex n)
quarterBandUp size = VG.generate size func
    where
    func idx 
        | m == 0 = 1    :+ 0
        | m == 1 = 0    :+ 1
        | m == 2 = (-1) :+ 0
        | m == 3 = 0    :+ (-1)
        where
        m = idx `mod` 4

