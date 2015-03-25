{-# LANGUAGE ScopedTypeVariables, FlexibleContexts #-}

{-| Utility functions for serializing and deserializing samples. -}
module SDR.Serialize (

    {-| Slow functions for serializing\/deserializing vectors to\/from
        bytestrings using the Cereal library. There must be a better 
        way to do this that doesn't involve copying.
    -}

    floatVecToByteString,
    doubleVecToByteString,
    floatVecFromByteString,
    doubleVecFromByteString,

    {-| Fast functions for serializing\/deserializing storable vectors to\/from
        bytestrings.
    -}

    toByteString,
    fromByteString,
    toHandle,
    fromHandle
    ) where

import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Storable
import Data.ByteString.Internal 
import Data.ByteString as BS
import System.IO

import Data.Vector.Generic                         as VG   hiding ((++))
import qualified Data.Vector.Generic.Mutable       as VGM
import Data.Vector.Storable                        as VS   hiding ((++))
import Data.Vector.Storable.Mutable                as VSM  hiding ((++))
import Data.Vector.Fusion.Stream.Monadic                   hiding ((++))
import qualified Data.Vector.Fusion.Stream         as VFS  hiding ((++))
import qualified Data.Vector.Fusion.Stream.Monadic as VFSM hiding ((++))

import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.ByteString as PB
import Data.Serialize hiding (Done)
import qualified Data.Serialize as S

-- | Convert a Vector of Floats to a ByteString.
floatVecToByteString    :: VG.Vector v Float  => v Float -> ByteString
floatVecToByteString vect = runPut $ VG.mapM_ putFloat32le vect

-- | Convert a Vector of Doubles to a ByteString.
doubleVecToByteString   :: VG.Vector v Double => v Double -> ByteString
doubleVecToByteString vect = runPut $ VG.mapM_ putFloat64le vect

-- | Convert a ByteString to a Vector of Floats.
floatVecFromByteString  :: VG.Vector v Float  => ByteString -> v Float
floatVecFromByteString bs = VG.unfoldrN (BS.length bs `div` 4) go bs
    where
    go bs = case runGetPartial getFloat32le bs of
                Fail _ _    -> Nothing
                Partial _   -> error "floatVecFromByteString: Partial"
                S.Done r b  -> Just (r, b)

-- | Convert a ByteString to a Vector of Doubles.
doubleVecFromByteString  :: VG.Vector v Double  => ByteString -> v Double
doubleVecFromByteString bs = VG.unfoldrN (BS.length bs `div` 8) go bs
    where
    go bs = case runGetPartial getFloat64le bs of
                Fail _ _    -> Nothing
                Partial _   -> error "doubleVecFromByteString"
                S.Done r b  -> Just (r, b)

-- | Convert a Vector of Storable values to a ByteString. This is fast as it is just a cast.
toByteString :: forall a. (Storable a) => Pipe (VS.Vector a) ByteString IO ()
toByteString = P.map $ \dat -> let (fp, o, sz) = VS.unsafeToForeignPtr dat in PS (castForeignPtr fp) o (sz * sizeOf (undefined :: a))

-- | Convert a ByteString to a Vector of Storable values. This is fast as it is just a cast.
fromByteString :: forall a. (Storable a) => Pipe ByteString (VS.Vector a) IO ()
fromByteString = P.map $ \(PS fp o l) -> VS.unsafeFromForeignPtr (castForeignPtr fp) o (l `quot` sizeOf (undefined :: a))

-- | Given a Handle, create a Consumer that dumps the Vectors written to it to a Handle.
toHandle :: (Storable a) => Handle -> Consumer (VS.Vector a) IO ()
toHandle handle = toByteString >-> PB.toHandle handle 

-- | Given a Handle, create a Producer that creates Vectors from data read from the Handle.
fromHandle :: forall a. (Storable a) => Int -> Handle -> Producer (VS.Vector a) IO ()
fromHandle samples handle = PB.hGet (samples * sizeOf (undefined :: a)) handle >-> fromByteString 

