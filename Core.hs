{- git-annex core functions
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Core where

import IO (try)
import System.Directory
import Control.Monad.State (liftIO)
import System.Path
import Control.Monad (when, unless, filterM)
import System.Posix.Files
import Data.Maybe

import Types
import Locations
import LocationLog
import UUID
import qualified GitRepo as Git
import qualified GitQueue
import qualified Annex
import qualified Backend
import Utility
import Messages

{- Runs a list of Annex actions. Catches IO errors and continues
 - (but explicitly thrown errors terminate the whole command).
 - Propigates an overall error status at the end.
 -}
tryRun :: AnnexState -> [Annex Bool] -> IO ()
tryRun state actions = tryRun' state 0 actions
tryRun' :: AnnexState -> Integer -> [Annex Bool] -> IO ()
tryRun' state errnum (a:as) = do
	result <- try $ Annex.run state a
	case (result) of
		Left err -> do
			Annex.eval state $ showErr err
			tryRun' state (errnum + 1) as
		Right (True,state') -> tryRun' state' errnum as
		Right (False,state') -> tryRun' state' (errnum + 1) as
tryRun' _ errnum [] =
	when (errnum > 0) $ error $ show errnum ++ " failed"
			
{- Sets up a git repo for git-annex. -}
startup :: Annex Bool
startup = do
	prepUUID
	autoUpgrade
	return True

{- When git-annex is done, it runs this. -}
shutdown :: Annex Bool
shutdown = do
	g <- Annex.gitRepo

	-- Runs all queued git commands.
	q <- Annex.queueGet
	unless (q == GitQueue.empty) $ do
		verbose $ liftIO $ putStrLn "Recording state in git..."
		liftIO $ GitQueue.run g q

	-- clean up any files left in the temp directory, but leave
	-- the tmp directory itself
	let tmp = annexTmpLocation g
	exists <- liftIO $ doesDirectoryExist tmp
	when (exists) $ liftIO $ removeDirectoryRecursive tmp
	liftIO $ createDirectoryIfMissing True tmp

	return True

{- configure git to use union merge driver on state files, if it is not
 - already -}
gitAttributes :: Git.Repo -> IO ()
gitAttributes repo = do
	exists <- doesFileExist attributes
	if (not exists)
		then do
			writeFile attributes $ attrLine ++ "\n"
			commit
		else do
			content <- readFile attributes
			when (all (/= attrLine) (lines content)) $ do
				appendFile attributes $ attrLine ++ "\n"
				commit
	where
		attrLine = stateLoc ++ "*.log merge=union"
		attributes = Git.attributes repo
		commit = do
			Git.run repo ["add", attributes]
			Git.run repo ["commit", "-m", "git-annex setup", 
					attributes]

{- set up a git pre-commit hook, if one is not already present -}
gitPreCommitHook :: Git.Repo -> IO ()
gitPreCommitHook repo = do
	let hook = Git.workTree repo ++ "/" ++ Git.gitDir repo ++
		"/hooks/pre-commit"
	exists <- doesFileExist hook
	if (exists)
		then putStrLn $ "pre-commit hook (" ++ hook ++ ") already exists, not configuring"
		else do
			writeFile hook $ "#!/bin/sh\n" ++
				"# automatically configured by git-annex\n" ++ 
				"git annex pre-commit .\n"
			p <- getPermissions hook
			setPermissions hook $ p {executable = True}

{- Checks if a given key is currently present in the annexLocation. -}
inAnnex :: Key -> Annex Bool
inAnnex key = do
	g <- Annex.gitRepo
	when (Git.repoIsUrl g) $ error "inAnnex cannot check remote repo"
	liftIO $ doesFileExist $ annexLocation g key

{- Calculates the relative path to use to link a file to a key. -}
calcGitLink :: FilePath -> Key -> Annex FilePath
calcGitLink file key = do
	g <- Annex.gitRepo
	cwd <- liftIO $ getCurrentDirectory
	let absfile = case (absNormPath cwd file) of
		Just f -> f
		Nothing -> error $ "unable to normalize " ++ file
	return $ relPathDirToDir (parentDir absfile) (Git.workTree g) ++
		annexLocationRelative key

{- Updates the LocationLog when a key's presence changes. -}
logStatus :: Key -> LogStatus -> Annex ()
logStatus key status = do
	g <- Annex.gitRepo
	u <- getUUID g
	logfile <- liftIO $ logChange g key u status
	Annex.queue "add" [] logfile

{- Runs an action, passing it a temporary filename to download,
 - and if the action succeeds, moves the temp file into 
 - the annex as a key's content. -}
getViaTmp :: Key -> (FilePath -> Annex Bool) -> Annex Bool
getViaTmp key action = do
	g <- Annex.gitRepo
	let dest = annexLocation g key
	let tmp = annexTmpLocation g ++ keyFile key
	liftIO $ createDirectoryIfMissing True (parentDir tmp)
	success <- action tmp
	if (success)
		then do
			liftIO $ renameFile tmp dest
			logStatus key ValuePresent
			return True
		else do
			-- the tmp file is left behind, in case caller wants
			-- to resume its transfer
			return False

{- List of keys whose content exists in .git/annex/objects/ -}
getKeysPresent :: Annex [Key]
getKeysPresent = do
	g <- Annex.gitRepo
	let top = annexObjectDir g
	contents <- liftIO $ getDirectoryContents top
	files <- liftIO $ filterM (isreg top) contents
	return $ map fileKey files
	where
		isreg top f = do
			s <- getFileStatus $ top ++ "/" ++ f
			return $ isRegularFile s

{- List of keys referenced by symlinks in the git repo. -}
getKeysReferenced :: Annex [Key]
getKeysReferenced = do
	g <- Annex.gitRepo
	files <- liftIO $ Git.inRepo g $ Git.workTree g
	keypairs <- mapM Backend.lookupFile files
	return $ map fst $ catMaybes keypairs

{- Uses the annex.version git config setting to automate upgrades. -}
autoUpgrade :: Annex ()
autoUpgrade = do
	g <- Annex.gitRepo

	case Git.configGet g field "0" of
		"0" -> do -- before there was repo versioning
			upgradeNote "Upgrading object directory layout..."
			
			setVersion
		v | v == currentVersion -> return ()
		_ -> error "this version of git-annex is too old for this git repository!"
	where
		currentVersion = "1"
		setVersion = Annex.setConfig field currentVersion
		field = "annex.version"
		upgradeNote s = verbose $ liftIO $ putStrLn $ "("++s++")"
