{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.TypedProtocol.PingPong.Codec where

import           Network.TypedProtocol.Core (PeerKind (..))
import           Network.TypedProtocol.Codec
import           Network.TypedProtocol.PingPong.Type

pingPongClientCodec
  :: forall m. Monad m
  => Codec AsClient PingPongState String m String
pingPongClientCodec = Codec encodeMsg decodeMsg
  where
   encodeMsg :: forall (st :: PingPongState) (st' :: PingPongState). ClientToken st -> Message st st' -> String
   encodeMsg ClientTokenIdle MsgPing = "ping"
   encodeMsg ClientTokenIdle MsgDone = "done"

   decodeMsg :: forall (st :: PingPongState). ServerToken st -> m (DecodeStep String String m (SomeMessage st))
   decodeMsg tok = return $ Partial $ \bytes -> case (tok, bytes) of
     (_, Nothing)                   -> return $ Fail "not enough input"
     (ServerTokenBusy, Just "pong") -> return $ Done (SomeMessage MsgPong) Nothing
     (_, Just _)                    -> return $ Fail "wrong input"

pingPongServerCodec
  :: forall m. Monad m
  => Codec AsServer PingPongState String m String
pingPongServerCodec = Codec encodeMsg decodeMsg
  where
   encodeMsg :: forall (st :: PingPongState) (st' :: PingPongState). ServerToken st -> Message st st' -> String
   encodeMsg ServerTokenBusy MsgPong = "pong"

   decodeMsg :: forall (st :: PingPongState). ClientToken st -> m (DecodeStep String String m (SomeMessage st))
   decodeMsg tok = return $ Partial $ \bytes -> case (tok, bytes) of
     (_, Nothing)                   -> return $ Fail "not enough input"
     (ClientTokenIdle, Just "ping") -> return $ Done (SomeMessage MsgPing) Nothing
     (ClientTokenIdle, Just "done") -> return $ Done (SomeMessage MsgDone) Nothing
     (_, Just _)                    -> return $ Fail "wrong input"
