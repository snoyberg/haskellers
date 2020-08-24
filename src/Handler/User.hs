{-# LANGUAGE QuasiQuotes, TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.User
    ( getUserR
    , getByIdentR
    , getFlagR
    , postFlagR
    , adminControls
    ) where

import Import
import Handler.Root (gravatar)
import Data.List (sortBy, intercalate)
import Data.Ord (comparing)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.UTF8 as SU
import Yesod.Form.Jquery (urlJqueryJs)
import Data.Time (getCurrentTime)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Text.Read
import qualified Data.ByteString.Base64 as B64
import qualified Crypto.Cipher.AES as AES
import Network.HTTP.Types (status301)
import Network.HTTP.Simple
import UnliftIO (tryAny)
import Control.Monad (when)

getByIdentR :: Handler Value
getByIdentR = do
    identS <- runInputGet $ ireq textField "ident"
    x <- runDB $ getBy $ UniqueIdent identS
    render <- getUrlRender
    case x of
        Nothing -> notFound
        Just (Entity _ (Ident { identUser = uid })) -> return $ object
            [ "id"  .= toPathPiece (uid :: UserId)
            , "url" .= render (UserR $ toPathPiece uid)
            ]

getUserR :: Text -> Handler TypedContent
getUserR input = do
    (uid, u) <-
        case Data.Text.Read.decimal input :: Either String (Int, Text) of
            Right (x, "") -> runDB $ do
                Just uid <- return $ fromPathPiece input
                liftIO $ print $ "Looking for: " ++ show x ++ ", uid == " ++ show uid
                u <- get404 uid
                mun <- getBy $ UniqueUsernameUser uid
                case mun of
                    Nothing -> return (uid, u)
                    Just (Entity _(Username _ un)) ->
                        lift $ redirectWith status301 $ UserR un
            _ -> runDB $ do
                mun <- getBy $ UniqueUsername input
                case mun of
                    Nothing -> lift notFound
                    Just (Entity _ (Username uid _)) -> do
                        u <- get404 uid
                        return (uid, u)
    mv <- maybeAuth
    let viewerIsAdmin = maybe False (userAdmin . entityVal) mv

    when (userBlocked u && ((entityKey <$> mv) /= Just uid) && not viewerIsAdmin) notFound

    midents <-
        if viewerIsAdmin
            then Just <$> runDB (selectList [IdentUser ==. uid] [Asc IdentIdent])
            else return Nothing

    skills <- runDB $ do
        x <- selectList [UserSkillUser ==. uid] [] >>= mapM (\(Entity _ y) -> do
            let sid = userSkillSkill y
            s <- get404 sid
            return (sid, T.unpack $ skillName s))
        return $ sortBy (comparing snd) x
    packages <- runDB
              $ fmap (map $ T.unpack . packageName . entityVal)
              $ selectList [PackageUser ==. uid] [Asc PackageName]
    screenNames <- runDB $ selectList
                    [ScreenNameUser ==. uid, ScreenNameService !=. GooglePlus]
                    [Asc ScreenNameService, Asc ScreenNameName]
    let email = fromMaybe "fake@email.com" $ userEmail u
    y <- getYesod
    let json = object
            $ ((:) ("id" .= toPathPiece uid))
            . ((:) ("name" .= userFullName u))
            . (case userWebsite u of
                Nothing -> id
                Just w -> (:) ("website" .= w))
            . (case userHaskellSince u of
                Nothing -> id
                Just e -> (:) ("haskell-since" .= show e))
            . (case userDesc u of
                Nothing -> id
                Just d -> (:) ("description" .= unTextarea d))
            . ((:) ("skills", array $ map snd skills))
            $ []
    let percentEncode = id -- FIXME
    let packdeps = "http://packdeps.haskellers.com/specific/?" ++
            intercalate "&"
                (map (\x -> "package=" ++ percentEncode x) packages)
    let sortaRoot = "https://www.sortasecret.com" :: String
    mencryptedEmail <-
      case (userEmail u, userEmailPublic u) of
        (Nothing, _) -> pure EENone
        (Just email', True) -> pure $ EEPlaintext email'
        (Just email', False) -> do
          req <-  setRequestQueryString [("secret", Just $ encodeUtf8 email')] <$>
                  parseRequestThrow (sortaRoot ++ "/v1/encrypt")
          eres <- tryAny $ httpBS req
          case eres of
            Left e -> do
              $logError $ T.pack $ show e
              pure $ EEError "Unable to communicate with Sorta Secret service"
            Right encrypted -> pure $ EEEncrypted $ decodeUtf8With lenientDecode $ getResponseBody encrypted
    flip defaultLayoutJson (return json) $ do
        setTitle $ toHtml $ "Haskellers profile for " `mappend` userFullName u
        addScriptEither $ urlJqueryJs y
        $(widgetFile "user")

data EncryptedEmail
  = EEPlaintext !Text
  | EEEncrypted !Text
  | EENone
  | EEError !Text

getFlagR :: UserId -> Handler Html
getFlagR uid = do
    u <- runDB $ get404 uid
    let userLink = userR ((uid, u), Nothing)
    defaultLayout $ do
        setTitle "Report a user"
        $(widgetFile "flag")

postFlagR :: UserId -> Handler ()
postFlagR uid = do
    mvid <- fmap (fmap entityKey) maybeAuth
    mmsg <- runInputPost $ iopt textField "message"
    let msg = fromMaybe "" mmsg

    u <- runDB $ do
        u <- get404 uid
        now <- liftIO getCurrentTime
        _ <- insert Message
            { messageClosed = False
            , messageWhen = now
            , messageFrom = mvid
            , messageRegarding = Just uid
            , messageText = Textarea $ "User has been reported\n\n" `mappend` msg
            }
        return u
    setMessage "The user has been reported to the admins. Thanks!"
    redirect $ userR ((uid, u), Nothing)

adminControls :: UserId -> User -> Widget
adminControls uid u = $(widgetFile "admin-controls")
