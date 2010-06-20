{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell,
             FlexibleInstances, FlexibleContexts, MultiParamTypeClasses,
             TypeOperators, TypeSynonymInstances #-}
module Distribution.Server.Users.State where

import Distribution.Server.Instances ()

import Distribution.Server.Users.Types (UserId,UserName,UserAuth)
import Distribution.Server.Users.Group as Group (UserList(..), enumerate, add, remove, empty)
import Distribution.Server.Users.Users as Users

import Data.Typeable (Typeable)
import Data.Maybe (isJust)

import Happstack.State
import qualified Data.Binary as Binary

import Control.Monad.Reader
import qualified Control.Monad.State as State

--TODO: substitute equivalent deriveSerializes
instance Version Users where
  mode = Versioned 0 Nothing

instance Serialize Users where
  putCopy = contain . Binary.put
  getCopy = contain Binary.get

instance Version UserList where
  mode = Versioned 0 Nothing
instance Serialize UserList where
  putCopy = contain . Binary.put
  getCopy = contain Binary.get

instance Version UserId where
  mode = Versioned 0 Nothing
instance Serialize UserId where
  putCopy = contain . Binary.put
  getCopy = contain Binary.get

instance Version UserName where
  mode = Versioned 0 Nothing
instance Serialize UserName where
  putCopy = contain . Binary.put
  getCopy = contain Binary.get

instance Version UserAuth where
  mode = Versioned 0 Nothing
instance Serialize UserAuth where
  putCopy = contain . Binary.put
  getCopy = contain Binary.get

instance Component Users where
  type Dependencies Users = End
  initialValue = Users.empty

--------------------------------------------

-- Returns 'Nothing' if the user name is in use
addUser :: UserName -> UserAuth -> Update Users (Maybe UserId)
addUser userName auth = updateUsers' updateFn formatFn
  where updateFn = Users.add userName auth
        formatFn = id

-- Disables the indicated user
setEnabledUser :: UserId -> Bool -> Update Users Bool
setEnabledUser uid en = updateUsers $ Users.setEnabled en uid

-- Deletes the indicated user. Cannot be re-enabled. The associated
-- user name is available for re-use 
deleteUser :: UserId -> Update Users Bool
deleteUser = updateUsers . Users.delete

-- Re-set the user autenication info
replaceUserAuth :: UserId -> UserAuth -> Update Users Bool
replaceUserAuth userId auth
    = updateUsers $ \users -> Users.replaceAuth users userId auth

-- updates the user db with a simpler function
updateUsers :: (Users -> Maybe Users) -> Update Users Bool
updateUsers f = updateUsers' updateFn isJust
    where updateFn users = fmap (swap . (,) ()) $ f users
          swap (x,y) = (y,x)

-- Helper function for updating the users db
updateUsers' :: (Users -> Maybe (Users, a)) -> (Maybe a -> b) -> Update Users b
updateUsers' f format = do
  users <- State.get
  liftM format $ case (f users) of
    Nothing -> return Nothing
    Just (users',a) -> do
      State.put users'
      return (Just a)

lookupUserName :: UserName -> Query Users (Maybe UserId)
lookupUserName = queryUsers . Users.lookupName

queryUsers :: (Users -> a) -> Query Users a
queryUsers queryFn = liftM queryFn ask

getUserDb :: Query Users Users
getUserDb = ask

replaceUserDb :: Users -> Update Users ()
replaceUserDb = State.put

listGroupMembers :: UserList -> Query Users [UserName]
listGroupMembers userList
    = do users <- ask
         return [ Users.idToName users uid | uid <- Group.enumerate userList ]

$(mkMethods ''Users ['addUser
                    ,'setEnabledUser
                    ,'deleteUser
                    ,'replaceUserAuth
                    ,'lookupUserName
                    ,'getUserDb
                    ,'replaceUserDb
                    ,'listGroupMembers
                    ])

-----------------------------------------------------

data HackageAdmins = HackageAdmins {
    adminList :: !Group.UserList
} deriving (Typeable)
$(deriveSerialize ''HackageAdmins)
instance Version HackageAdmins where
    mode = Versioned 0 Nothing

getHackageAdmins :: Query HackageAdmins UserList
getHackageAdmins = asks adminList

modifyHackageAdmins :: (UserList -> UserList) -> Update HackageAdmins ()
modifyHackageAdmins func = State.modify (\users -> users { adminList = func (adminList users) })

addHackageAdmin :: UserId -> Update HackageAdmins ()
addHackageAdmin uid = modifyHackageAdmins (Group.add uid)

removeHackageAdmin :: UserId -> Update HackageAdmins ()
removeHackageAdmin uid = modifyHackageAdmins (Group.remove uid)

instance Component HackageAdmins where
    type Dependencies HackageAdmins = End
    initialValue = HackageAdmins Group.empty

$(mkMethods ''HackageAdmins
                    ['getHackageAdmins
                    ,'addHackageAdmin
                    ,'removeHackageAdmin])

--------------------------------------------------------------------------

data MirrorClients = MirrorClients {
    mirrorClients :: !Group.UserList
} deriving (Typeable)
$(deriveSerialize ''MirrorClients)
instance Version MirrorClients where
    mode = Versioned 0 Nothing

getMirrorClients :: Query MirrorClients UserList
getMirrorClients = asks mirrorClients

modifyMirrorClients :: (UserList -> UserList) -> Update MirrorClients ()
modifyMirrorClients func = State.modify (\users -> users { mirrorClients = func (mirrorClients users) })

addMirrorClient :: UserId -> Update MirrorClients ()
addMirrorClient uid = modifyMirrorClients (Group.add uid)

removeMirrorClient :: UserId -> Update MirrorClients ()
removeMirrorClient uid = modifyMirrorClients (Group.remove uid)

instance Component MirrorClients where
    type Dependencies MirrorClients = End
    initialValue = MirrorClients Group.empty

$(mkMethods ''MirrorClients
                    ['getMirrorClients
                    ,'addMirrorClient
                    ,'removeMirrorClient])
