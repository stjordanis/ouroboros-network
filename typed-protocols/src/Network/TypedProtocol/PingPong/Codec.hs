{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.TypedProtocol.PingPong.Codec where

import           Network.TypedProtocol.Codec
import           Network.TypedProtocol.PingPong.Type

pingPongCodec :: Codec pk PingPongState String m String
pingPongCodec = undefined

{--
  - pingPongCodecServer
  -   :: forall m pk. Monad m
  -   => Codec AsServer PingPongState String m String
  - pingPongCodecServer = Codec encodeMsg decodeMsg
  -   where
  -    encodeMsg :: forall (st :: PingPongState) (st' :: PingPongState). Message st st' -> String
  -    encodeMsg MsgPing = "ping"
  -    encodeMsg MsgPong = "pong"
  -    encodeMsg MsgDone = "done"
  - 
  -    decodeMsg :: forall (st :: PingPongState) tok. tok st -> m (DecodeStep String String m (SomeMessage st))
  -    decodeMsg tok = return $ Partial $ \bytes -> case bytes of
  -      Nothing  -> return $ Fail "not enough input"
  -      Just bts -> case decodePingPongMessage tok bts of
  -        Just msg -> return $ Done msg ""
  -        Nothing  -> return $ Fail "wrong input"
  --}

{--
  - decodePingPongMessage :: forall (st :: PingPongState) (tok :: PingPongState -> *). 
  -                          tok st
  -                       -> String
  -                       -> Maybe (SomeMessage st)
  - decodePingPongMessage _ _ = Nothing
  --}
{--
  - decodePingPongMessage TokIdle "ping" = Just (SomeMessage MsgPing)
  - decodePingPongMessage TokIdle "done" = Just (SomeMessage MsgDone)
  - decodePingPongMessage TokBusy "pong" = Just (SomeMessage MsgPong)
  - decodePingPongMessage _       _      = Nothing
  --}
