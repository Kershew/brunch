{exec} = require 'child_process'
mkdirp = require 'mkdirp'
rimraf = require 'rimraf'
sysPath = require 'path'
logger = require '../logger'
fs_utils = require '../fs_utils'

install = (rootPath, callback = (->)) ->
  prevDir = process.cwd()
  logger.info 'Installing packages...'
  process.chdir rootPath
  # Install node packages.
  exec 'npm install', (error, stdout, stderr) ->
    process.chdir prevDir
    return callback stderr.toString() if error?
    callback null, stdout

# Remove git metadata and run npm install.
removeAndInstall = (rootPath, callback) ->
  rimraf (sysPath.join rootPath, '.git'), (error) ->
    return logger.error error if error?
    install rootPath, callback

module.exports = create = (options, callback = (->)) ->
  {rootPath, skeleton} = options

  copySkeleton = (skeletonPath) ->
    skeletonDir = sysPath.join __dirname, '..', 'skeletons'
    skeletonPath ?= sysPath.join skeletonDir, 'simple-coffee'
    logger.debug "Copying skeleton from #{skeletonPath}"

    copyDirectory = (from) ->
      fs_utils.copyIfExists from, rootPath, no, (error) ->
        return logger.error error if error?
        logger.info 'Created brunch directory layout'
        removeAndInstall rootPath, callback

    mkdirp rootPath, 0o755, (error) ->
      return logger.error error if error?
      fs_utils.exists skeletonPath, (exists) ->
        return logger.error "Skeleton '#{skeleton}' doesn't exist" unless exists
        copyDirectory skeletonPath

  cloneSkeleton = (URL) ->
    logger.debug "Cloning skeleton from git URL #{URL}"
    exec "git clone #{URL} #{rootPath}", (error, stdout, stderr) ->
      return logger.error "Git clone error: #{stderr.toString()}" if error?
      logger.info 'Created brunch directory layout'
      removeAndInstall rootPath, callback

  fs_utils.exists rootPath, (exists) ->
    return logger.error "Directory '#{rootPath}' already exists" if exists
    if /(https?|git)(:\/\/|@)/.test skeleton
      cloneSkeleton skeleton, callback
    else
      copySkeleton skeleton, callback

module.exports.install = install