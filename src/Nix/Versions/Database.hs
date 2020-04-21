{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

{-|
Save and retrieving Database types from persistent storage
-}

module Nix.Versions.Database
    ( Connection
    , RevisionState(..)
    , connect
    , disconnect
    , withConnection

    -- Write
    , save
    , saveRevision

    -- Read
    , versions
    , revisions
    , revisionsByHash
    ) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (catchJust)
import Control.Monad.Catch (MonadMask, bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Int (Int64)
import Data.Functor ((<&>))
import Data.Maybe (fromMaybe)
import Data.String (fromString, IsString)
import Data.Text (Text, pack, unpack)
import Data.Time.Calendar (Day(..), toModifiedJulianDay)
import Database.SQLite.Simple (ToRow(toRow), FromRow(fromRow), SQLData(..), NamedParam((:=)))
import Nix.Revision (Channel, Revision(..), RevisionPackages, Package(..))
import Nix.Versions.Types (CachePath(..), DBFile(..), Hash(..), Version(..), Name(..), Commit(..))

import qualified Data.HashMap.Strict as HashMap
import qualified Database.SQLite.Simple as SQL

newtype Connection = Connection SQL.Connection

-- Constants

db_REVISIONS, db_PACKAGE_VERSIONS, db_PACKAGE_NAMES :: IsString a => a
db_PACKAGE_NAMES    = "PACKAGE_NAMES"
db_PACKAGE_VERSIONS = "PACKAGE_VERSIONS"
db_REVISIONS        = "REVISIONS"

-- | Get a connection and prepare database for usage
connect :: MonadIO m => CachePath -> DBFile -> m Connection
connect (CachePath dir) (DBFile fname) = liftIO $ do
    conn <- SQL.open $ dir <> "/" <> fname
    -- Enable foreign key constraints.
    -- It's really weird that they would otherwise just not work.
    SQL.execute_ conn "PRAGMA foreign_keys = ON"
    ensureTablesAreCreated conn
    return $ Connection conn

ensureTablesAreCreated :: SQL.Connection -> IO ()
ensureTablesAreCreated conn = do
    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_REVISIONS <> " "
                        -- | Details about the Revision's commit
                        <> "( COMMIT_HASH       TEXT        NOT NULL"
                        <> ", COMMIT_DAY        INTEGER     NOT NULL"
                        <> ", CHANNEL           TEXT        NOT NULL" -- TODO: Foreign key
                        -- | Even though the commit might have been done in a certain date,
                        -- we added it to the database to represent the state of nixpkgs
                        -- on a specific date, which may be different from the exact commit date.
                        <> ", REPRESENTS_DAY    INTEGER     NOT NULL"
                        -- | Whether we were able to successfully add all Revision packages to the table
                        <> ", STATE             TEXT        NOT NULL"
                        -- The same commit hash can be used for multiple channels
                        <> ", PRIMARY KEY (COMMIT_HASH, CHANNEL)"
                        <> ")"

    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_NAMES <> " "
                        <> "( PACKAGE_NAME TEXT PRIMARY KEY"
                        <> ")"

    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_VERSIONS <> " "
                        <> "( PACKAGE_NAME  TEXT NOT NULL"
                        <> ", VERSION_NAME  TEXT NOT NULL"
                        <> ", REVISION_HASH TEXT NOT NULL"
                        <> ", DESCRIPTION   TEXT"
                        <> ", NIXPATH       TEXT"
                        <> ", PRIMARY KEY (PACKAGE_NAME, VERSION_NAME)"
                        <> ", FOREIGN KEY (PACKAGE_NAME) REFERENCES " <> db_PACKAGE_NAMES <> "(PACKAGE_NAME)"
                        <> ")"

disconnect :: MonadIO m => Connection -> m ()
disconnect (Connection conn) = liftIO $ SQL.close conn

withConnection :: (MonadMask m, MonadIO m) => CachePath -> DBFile -> (Connection -> m a) -> m a
withConnection cache file = bracket (connect cache file) disconnect

-------------------------------------------------------------------------------
-- Read

-- | Retrieve all versions available for a package
-- This will be on the order of the tens, or maximum the
-- hundreds, so it is fine to just return all of them
versions :: MonadIO m => Connection -> Channel -> Name -> m [(Hash, Package)]
versions (Connection conn) channel (Name name) = liftIO $ do
    results <- SQL.queryNamed
        conn
        (fromString $ unwords
            [ "SELECT"
            ,   "PACKAGE_NAME,"
            ,   "VERSION_NAME,"
            ,   "REVISION_HASH,"
            ,   "DESCRIPTION,"
            ,   "NIXPATH"
            , "FROM"
            , db_PACKAGE_VERSIONS, "INNER JOIN", db_REVISIONS
            , "WHERE"
            , "COMMIT_HASH = REVISION_HASH"
            , "AND CHANNEL =  :channel"
            , "AND PACKAGE_NAME = :name"
            ]
        )
        [ ":name"    := unpack name
        , ":channel" := show channel
        ]
    return $ toVersionInfo <$> results
        where
            toVersionInfo  (SQLPackageVersion (_, pkg, hash)) = (hash, pkg)

-- | Retrieve all revisions available in the database
-- This will be between one hundred and one thousand.
revisions :: MonadIO m => Connection -> Channel -> m [(Day, Revision, RevisionState)]
revisions (Connection conn) channel = liftIO $ do
    results <- SQL.query
        conn
        ("SELECT * FROM " <> db_REVISIONS <> " WHERE CHANNEL = ?")
        [show channel]
    return $ toInfo <$> results

revisionsByHash :: MonadIO m => Connection -> Hash ->  m [(Day, Revision, RevisionState)]
revisionsByHash (Connection conn) (Hash hash) = liftIO $ do
    results <- SQL.query
        conn
        ("SELECT * FROM " <> db_REVISIONS <> " WHERE COMMIT_HASH = ?")
        [show hash]
    return $ toInfo <$> results

toInfo :: SQLRevision -> (Day, Revision, RevisionState)
toInfo (SQLRevision day revision state) = (day, revision, state)

-------------------------------------------------------------------------------
-- Write

-- | When there is a problem building the revision this function allows us
-- to record that in the database so that later we don't try to build it again
saveRevision :: MonadIO m => Connection -> Day -> Revision -> RevisionState -> m ()
saveRevision conn represents revision state =
    liftIO $ persistRevision conn represents revision state

-- | Save the entire database
save :: MonadIO m => Connection -> Day -> Revision -> RevisionPackages -> m ()
save conn represents revision packages = liftIO $ do
    persistRevisionWithState Incomplete
    mapConcurrently_ persistPackage (HashMap.toList packages)
    persistRevisionWithState Success
    where
        Revision _ (Commit hash _) = revision

        persistPackage (name, info) =
            persistVersion conn hash name info

        persistRevisionWithState =
            persistRevision conn represents revision


persistRevision :: Connection -> Day -> Revision -> RevisionState -> IO ()
persistRevision (Connection conn) represents revision state =
    SQL.execute conn
            ("INSERT OR REPLACE INTO " <> db_REVISIONS <> " VALUES (?,?,?,?,?)")
            (SQLRevision represents revision state)

-- | Save the version info of a package in the database
persistVersion :: Connection -> Hash -> Name -> Package -> IO ()
persistVersion (Connection conn) hash name info =
    catchJust noPackageWithThatName
        insertVersion
        (\_ -> insertPackageName >> insertVersion)
    where
        insertVersion = SQL.execute conn
            ("INSERT OR REPLACE INTO " <> db_PACKAGE_VERSIONS <> " VALUES (?,?,?,?,?)")
            (SQLPackageVersion (name, info, hash))

        insertPackageName = SQL.execute conn
            ("INSERT OR REPLACE INTO " <> db_PACKAGE_NAMES <> " VALUES (?)")
            (SQLPackageName name)

        noPackageWithThatName = isConstraintError

        isConstraintError :: SQL.SQLError -> Maybe ()
        isConstraintError err =
            if SQL.sqlError err == SQL.ErrorConstraint
               then Just ()
               else Nothing


-- | Whether all revision entries were added to the table.
data RevisionState
    = Success            -- ^ All revision packages were successfully added to the DB
    | Incomplete         -- ^ The process of adding packages to the DB was started but not finished
    | InvalidRevision    -- ^ This revision cannot be built. It is not worth trying again.
    deriving (Show, Eq, Enum, Read)

data SQLRevision = SQLRevision Day Revision RevisionState

instance FromRow SQLRevision where
    fromRow = construct
        <$> (SQL.field <&> Hash)
        <*> (SQL.field <&> ModifiedJulianDay . fromInteger)
        <*> (SQL.field <&> read)
        <*> (SQL.field <&> ModifiedJulianDay . fromInteger)
        <*> (SQL.field <&> read)
        where
            construct :: Hash -> Day -> Channel -> Day -> RevisionState -> SQLRevision
            construct hash date channel represents state =
                SQLRevision represents (Revision channel (Commit hash date)) state

instance ToRow SQLRevision where
    toRow (SQLRevision represents (Revision channel (Commit hash date)) state) =
        [ SQLText    $ fromHash hash                   -- ^ COMMIT_HASH
        , SQLInteger $ dayToInt date                   -- ^ COMMIT_DAY
        , SQLText    $ pack $ show channel             -- ^ CHANNEL
        , SQLInteger $ dayToInt represents             -- ^ REPRESENTS_DAY
        , SQLText    $ pack $ show state               -- ^ STATE
        ]


newtype SQLPackageName = SQLPackageName Name

instance ToRow SQLPackageName where
    toRow (SQLPackageName (Name name)) = [SQLText name]

instance FromRow SQLPackageName where
    fromRow = (SQLPackageName . Name) <$> SQL.field

newtype SQLPackageVersion = SQLPackageVersion (Name, Package, Hash)

instance ToRow SQLPackageVersion where
    toRow (SQLPackageVersion (name, Package { description, nixpkgsPath, version }, hash)) =
        [ SQLText $ fromName name                   -- ^ PACKAGE_NAME
        , SQLText $ fromVersion version             -- ^ VERSION_NAME
        , SQLText $ fromHash hash                   -- ^ REVISION_HASH
        , nullable $ SQLText <$> description        -- ^ DESCRIPTION
        , nullable $ SQLText . pack <$> nixpkgsPath -- ^ NIXPATH
        ]

nullable :: Maybe SQLData -> SQLData
nullable = fromMaybe SQLNull

instance FromRow SQLPackageVersion where
    fromRow = create
            <$> (SQL.field <&> Name)
            <*> (SQL.field <&> Version)
            <*> (SQL.field <&> Hash)
            <*> (SQL.field)
            <*> (SQL.field)
        where
            create :: Name -> Version -> Hash -> Maybe Text -> Maybe Text -> SQLPackageVersion
            create name version revision description nixpath =
                SQLPackageVersion
                    ( name
                    , Package
                        { version = version
                        , description = description
                        , nixpkgsPath = unpack <$> nixpath
                        }
                    , revision
                    )

dayToInt :: Day -> Int64
dayToInt = fromInteger . toModifiedJulianDay
