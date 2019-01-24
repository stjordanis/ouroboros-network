{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE NamedFieldPuns             #-}

module Network.TypedProtocol.Codec where

import           Network.TypedProtocol.Core
  ( CurrentToken
  , TerminalToken
  , FlipPeer
  , Message
  , PeerKind
  )

import           Control.Monad.ST (ST)
import           Control.Monad.Class.MonadST

import qualified Codec.CBOR.Encoding as CBOR (Encoding)
import qualified Codec.CBOR.Read     as CBOR
import qualified Codec.CBOR.Decoding as CBOR (Decoder)
import qualified Codec.CBOR.Write    as CBOR

import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Builder.Extra as BS
import qualified Data.ByteString.Lazy.Internal as LBS (smallChunkSize)
import qualified Data.ByteString.Lazy          as LBS

data Codec (pk :: PeerKind) ps failure m bytes = Codec {
       encode :: forall (st :: ps) (st' :: ps).
                 CurrentToken pk st
              -> Message st st'
              -> bytes,

       decode :: forall (st :: ps).
                 CurrentToken (FlipPeer pk) st
              -> m (DecodeStep bytes failure m (SomeMessage st))
     }

transformCodec
  :: Functor m
  => (bytes  -> bytes')
  -> (bytes' -> bytes)
  -> Codec pk ps failure m bytes
  -> Codec pk ps failure m bytes'
transformCodec to from Codec {encode, decode} = Codec {
    encode = fmap to . encode,
    decode = fmap (transformDecodeStep to from) . decode
  }

-- The types here are pretty fancy. The decode is polymorphic in the protocol
-- state, but only for kinds that are the same kind as the protocol state.
-- The StateToken is a type family that resolves to a singleton, and the
-- result uses existential types to hide the unknown type of the state we're
-- transitioning to.
--
-- Both the Message and StateToken data families are indexed on the kind ps
-- which is why it has to be a paramater here, otherwise these functions
-- are unusable.


data DecodeStep bytes failure m a =
    -- | The decoder has consumed the available input and needs more
    -- to continue. Provide @'Just'@ if more input is available and
    -- @'Nothing'@ otherwise, and you will get a new @'DecodeStep'@.
    Partial (Maybe bytes -> m (DecodeStep bytes failure m a))

    -- | The decoder has successfully finished. This provides the decoded
    -- result value plus any unused input.
  | Done a (Maybe bytes)

    -- | The decoder ran into an error. The decoder either used
    -- @'fail'@ or was not provided enough input.
  | Fail failure

transformDecodeStep
  :: Functor m
  => (bytes -> bytes')
  -> (bytes' -> bytes)
  -> DecodeStep bytes  failure m a
  -> DecodeStep bytes' failure m a
transformDecodeStep to from (Partial fn) = Partial $ fmap (transformDecodeStep to from) . fn . fmap from
transformDecodeStep to _ (Done a bs) = Done a (fmap to bs)
transformDecodeStep _ _ (Fail failure) = Fail failure

data SomeMessage (st :: ps) where
     SomeMessage :: Message st st' -> SomeMessage st


{-
serialiseCodec :: (MonadST m, Serialise.Serialise a)
               => Codec ByteString CBOR.DeserialiseFailure m a
serialiseCodec = cborCodec Serialise.encode Serialise.decode 
-}

cborCodec :: forall m pk ps. MonadST m
          => (forall (st :: ps) (st' :: ps). Message st st' -> CBOR.Encoding)
          -> (forall (st :: ps) s. CurrentToken (FlipPeer pk) st -> CBOR.Decoder s (SomeMessage st))
          -> Codec pk ps CBOR.DeserialiseFailure m ByteString
cborCodec cborEncode cborDecode =
    Codec {
      encode = convertCborEncoder $ const cborEncode,
      decode = \tok -> convertCborDecoder' (cborDecode tok)
    }

convertCborEncoder :: (tok -> a -> CBOR.Encoding) -> tok -> a -> ByteString
convertCborEncoder cborEncode =
    fmap CBOR.toStrictByteString
  . cborEncode

{-# NOINLINE toLazyByteString #-}
toLazyByteString :: BS.Builder -> LBS.ByteString
toLazyByteString = BS.toLazyByteStringWith strategy LBS.empty
  where
    strategy = BS.untrimmedStrategy 800 LBS.smallChunkSize

convertCborDecoder' :: MonadST m
                    => (forall s. CBOR.Decoder s a)
                    -> m (DecodeStep ByteString CBOR.DeserialiseFailure m a)
convertCborDecoder' cborDecode =
    withLiftST (convertCborDecoder cborDecode)

convertCborDecoder :: forall s m a. Functor m
                   => (CBOR.Decoder s a)
                   -> (forall b. ST s b -> m b)
                   -> m (DecodeStep ByteString CBOR.DeserialiseFailure m a)
convertCborDecoder cborDecode liftST =
    go <$> liftST (CBOR.deserialiseIncremental cborDecode)
  where
    go (CBOR.Done  trailing _ x)
      | BS.null trailing                  = Done x Nothing
      | otherwise                         = Done x (Just trailing)
    go (CBOR.Fail _trailing _off failure) = Fail failure
    go (CBOR.Partial k)                   = Partial (fmap go . liftST . k)