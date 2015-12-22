{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Service
 ( runProviderService
 , Port
 ) where

import System.IO (stdout, hFlush)
import qualified Data.List as L
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as EP
import qualified Network.Wai as W
import qualified Network.HTTP.Types as H
import qualified Network.Wai.Handler.Warp as Warp
import qualified System.Directory as D
import qualified Data.CaseInsensitive as CI

import qualified Pact as Pact
import qualified Provider as Provider

type Port = Int

keyOrder :: [T.Text]
keyOrder =
 [ "consumer", "provider", "interactions"
 , "description", "provider_state", "request", "response"
 , "status"
 , "method", "path", "query", "headers", "body"
 ]

encodePrettyCfg :: EP.Config
encodePrettyCfg = EP.Config { EP.confIndent = 4, EP.confCompare = EP.keyOrder keyOrder }


runProviderService :: Port -> IO ()
runProviderService p = do
  putStrLn $ "manners: listening on port " ++ (show p)
  hFlush stdout
  fakeProviderState <- Provider.newFakeProviderState
  Warp.run p (providerService fakeProviderState)

providerService :: Provider.FakeProviderState -> W.Application
providerService fakeProviderState request respond =
  case route of

    ("POST", ["interactions"], True) -> do
      putStrLn "Setup interaction"
      body <- W.strictRequestBody request
      let (Just interaction) = Aeson.decode body :: Maybe Pact.Interaction
      putStrLn (show interaction)
      Provider.runDebug fakeProviderState $
        Provider.addInteraction interaction
      respond . responseData $ object ["interaction" .= interaction]

    ("PUT", ["interactions"], True) -> do
      putStrLn "Set interactions"
      body <- W.strictRequestBody request
      let (Just interactionWrapper) = Aeson.decode body :: Maybe Pact.InteractionWrapper
      let interactions = Pact.wrapperInteractions interactionWrapper
      putStrLn (show interactions)
      Provider.runDebug fakeProviderState $
        Provider.setInteractions interactions
      respond . responseData $ object ["interactions" .= interactions]

    ("DELETE", ["interactions"], True) -> do
      putStrLn "Reset interactions"
      Provider.runDebug fakeProviderState $
        Provider.resetInteractions
      respond . responseData $ object ["interactions" .= ()]

    ("GET", ["interactions", "verification"], True) -> do
      putStrLn "Verify interactions"
      isSuccessful <- Provider.runDebug fakeProviderState $
        Provider.verifyInteractions
      putStrLn (show $ isSuccessful)
      respond $ if isSuccessful then responseData () else responseError APIErrorVerifyFailed

    ("POST", ["pact"], True) -> do
      putStrLn "Write pact"
      body <- W.strictRequestBody request
      let (Just contractDesc) = Aeson.decode body :: Maybe Pact.ContractDescription
      putStrLn (show contractDesc)
      verifiedInteractions <- Provider.runDebug fakeProviderState $
        Provider.getVerifiedInteractions
      let contract = contractDesc { Pact.contractInteractions = reverse verifiedInteractions }
      putStrLn (show contract)
      let marshalledContract = EP.encodePretty' encodePrettyCfg contract
      let fileName = "pact/" ++ (Pact.serviceName . Pact.contractConsumer $ contract) ++ "-" ++ (Pact.serviceName . Pact.contractProvider $ contract) ++ ".json"
      D.createDirectoryIfMissing True "pact"
      BL.writeFile fileName marshalledContract
      respond $ responseData (object ["generatedContract" .= fileName])

    _ -> do
      putStrLn "Default handler"
      encodedBody <- W.strictRequestBody request
      let inMethod = C.unpack $ W.requestMethod request
      let inPath = filter (/='?') $ C.unpack $ W.rawPathInfo request
      let inQuery = Pact.Query $ H.parseSimpleQuery $ W.rawQueryString request
      let inHeaders = Pact.convertHeadersToJson $ W.requestHeaders request
      let inBody = decode encodedBody
      let inputRequest = Pact.Request inMethod inPath inQuery inHeaders inBody

      putStrLn (show inputRequest)

      eitherInteraction <- Provider.runDebug fakeProviderState $
        Provider.recordRequest inputRequest

      respond $ case eitherInteraction of
        (Right interaction) -> let response          = Pact.interactionResponse interaction
                                   resStatus         = toEnum $ case Pact.responseStatus response of
                                                         (Just statusCode) -> statusCode
                                                         Nothing           -> 200
                                   resHeaders        = Pact.convertHeadersFromJson $ Pact.responseHeaders response
                                   resBody           = case Pact.responseBody response of
                                                         (Just body)    -> encode body
                                                         Nothing        -> ""
                               in W.responseLBS resStatus resHeaders resBody
        (Left []) -> responseError APIErrorNoInteractionsConfigured
        (Left failures) -> responseError $ APIErrorNoInteractionMatch failures

  where route = (W.requestMethod request, W.pathInfo request, isAdminRequest)
        isAdminRequest =
          case L.find hasAdminHeader (W.requestHeaders request)
            of (Just _) -> True
               _ -> False
        hasAdminHeader (h, v) = CI.mk h == CI.mk "X-Pact-Mock-Service" && CI.mk v == CI.mk "True"

responseData :: forall a. (ToJSON a) => a -> W.Response
responseData dat = W.responseLBS H.status200 [("Content-Type", "application/json")] $ encodeAPI (APIResponseSuccess dat :: APIResponse a ())

responseError :: APIError -> W.Response
responseError err = W.responseLBS H.status500 [("Content-Type", "application/json")] $ encodeAPI (APIResponseFailure err :: APIResponse () APIError)

encodeAPI :: (ToJSON a, ToJSON b) => APIResponse a b -> BL.ByteString
encodeAPI resp = EP.encodePretty' encodeAPICfg resp
  where
    encodeAPICfg :: EP.Config
    encodeAPICfg = EP.Config { EP.confIndent = 4, EP.confCompare = EP.keyOrder cmp }
      where cmp = [ "name", "description", "interactions", "interaction", "failedValidations" ] ++ keyOrder

data APIResponse a b = APIResponseSuccess a | APIResponseFailure b
instance (ToJSON a, ToJSON b) => ToJSON (APIResponse a b) where
  toJSON (APIResponseSuccess d) = object ["data" .= d]
  toJSON (APIResponseFailure e) = object ["error" .= e]

data APIError = APIErrorVerifyFailed
              | APIErrorNoInteractionsConfigured
              | APIErrorNoInteractionMatch [(Pact.Interaction, [Pact.ValidationError])]
instance ToJSON APIError where
  toJSON APIErrorVerifyFailed = object
    [ "name" .= ("APIErrorVerifyFailed" :: String)
    , "description" .= ("Verification failed" :: String)
    ]
  toJSON APIErrorNoInteractionsConfigured = object
    [ "name" .= ("APIErrorNoInteractionsConfigured" :: String)
    , "description" .= ("No interactions are configured yet" :: String)
    ]
  toJSON (APIErrorNoInteractionMatch failures) = object
    [ "name" .= ("APIErrorNoInteractionMatch" :: String)
    , "description" .= ("No matching interaction found" :: String)
    , "interactions" .= map formatFailure failures
    ]
    where
      formatFailure (interaction, errors) = object ["interaction" .= interaction, "failedValidations" .= errors]
