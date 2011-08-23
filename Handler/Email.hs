{-# LANGUAGE TemplateHaskell, OverloadedStrings, QuasiQuotes #-}
{-# LANGUAGE CPP #-}
module Handler.Email
    ( postResetEmailR
    , postSendVerifyR
    , getVerifyEmailR
    ) where

import Haskellers
import Control.Monad (when)
import Network.Mail.Mime
import Network.Mail.Mime.SES
import System.Random (newStdGen)
import Data.Maybe (isJust)
import qualified Data.ByteString.Lazy.UTF8 as LU
import StaticFiles (logo_png)
import Data.Text (Text, pack, unpack)
import SESCreds (access, secret)
import Data.Text.Encoding (encodeUtf8)
import Text.Blaze.Renderer.Utf8 (renderHtml)
import Text.Hamlet (shamlet)

postResetEmailR :: Handler ()
postResetEmailR = do
    (uid, _) <- requireAuth
    runDB $ update uid
        [ UserVerifiedEmail =. False
        , UserEmail =. Nothing
        , UserVerkey =. Nothing
        ]
    setMessage "Email address reset. Please verify a new address."
    redirect RedirectTemporary ProfileR

getVerifyEmailR :: Text -> Handler ()
getVerifyEmailR verkey = do
    (uid, u) <- requireAuth
    if Just verkey == userVerkey u && isJust (userEmail u)
        then do
            runDB $ update uid
                [ UserVerifiedEmail =. True
                , UserVerkey =. Nothing
                ]
            setMessage "Your email address has been verified."
        else setMessage "Invalid verification key"
    redirect RedirectTemporary ProfileR

postSendVerifyR :: Handler ()
postSendVerifyR = do
    (uid, u) <- requireAuth
    when (userVerifiedEmail u) $ do
        setMessage "You already have a verified email address."
        redirect RedirectTemporary ProfileR
    res <- runInputPost $ iopt emailField "email"
    case res of
        Just email -> do
            stdgen <- liftIO newStdGen
            let verkey = pack $ fst $ randomString 10 stdgen
            runDB $ update uid [ UserEmail =. Just email
                               , UserVerkey =. Just verkey
                               ]
            render <- getUrlRender
            let url = render $ VerifyEmailR verkey
            let ses = SES
                    { sesFrom = "webmaster@haskellers.com"
                    , sesTo = [encodeUtf8 email]
                    , sesAccessKey = access
                    , sesSecretKey = secret
                    }
            liftIO $ renderSendMailSES ses Mail
                { mailHeaders =
                    [ ("From", "webmaster@haskellers.com")
                    , ("To", email)
                    , ("Subject", "Verify your email address")
                    ]
                , mailParts = return
                    [ Part "text/plain" None Nothing [] $ LU.fromString $ unlines
                        [ "Please go to the URL below to verify your email address."
                        , ""
                        , unpack url
                        ]
                    , Part "text/html" None Nothing [] $ renderHtml [shamlet|\
<img src="#{render (StaticR logo_png)}" alt="Haskellers">
<p>Please go to the URL below to verify your email address.
<p>
    <a href="#{url}">#{url}
|]
                    ]
                }
            setMessage "A confirmation link has been sent."
        Nothing -> setMessage "You entered an invalid email address."
    redirect RedirectTemporary ProfileR
