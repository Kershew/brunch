'use strict'

{exec} = require 'child_process'
coffeescript = require 'coffee-script'
http = require 'http'
fs = require 'fs'
os = require 'os'
sysPath = require 'path'
logger = require 'loggy'

# Extends the object with properties from another object.
# Example
#
#   extend {a: 5, b: 10}, {b: 15, c: 20, e: 50}
#   # => {a: 5, b: 15, c: 20, e: 50}
#
exports.extend = extend = (object, properties) ->
  Object.keys(properties).forEach (key) ->
    object[key] = properties[key]
  object

recursiveExtend = (object, properties) ->
  Object.keys(properties).forEach (key) ->
    value = properties[key]
    if typeof value is 'object' and value?
      recursiveExtend object[key], value
    else
      object[key] = value
  object

exports.deepFreeze = deepFreeze = (object) ->
  Object.keys(Object.freeze object)
    .map (key) ->
      object[key]
    .filter (value) ->
      typeof value is 'object' and value? and not Object.isFrozen(value)
    .forEach(deepFreeze)
  object

exports.formatError = (error, path) ->
  "#{error.brunchType} of '#{path}'
 failed. #{error.toString().slice(7)}"

exports.install = install = (rootPath, callback = (->)) ->
  prevDir = process.cwd()
  logger.info 'Installing packages...'
  process.chdir rootPath
  # Install node packages.
  exec 'npm install', (error, stdout, stderr) ->
    process.chdir prevDir
    if error?
      log = stderr.toString()
      logger.error log
      return callback log
    callback null, stdout

exports.replaceSlashes = replaceSlashes = (config) ->
  changePath = (string) -> string.replace(/\//g, '\\')
  files = config.files or {}
  Object.keys(files).forEach (language) ->
    lang = files[language] or {}
    order = lang.order or {}

    # Modify order.
    Object.keys(order).forEach (orderKey) ->
      lang.order[orderKey] = lang.order[orderKey].map(changePath)

    # Modify join configuration.
    switch toString.call(lang.joinTo)
      when '[object String]'
        lang.joinTo = changePath lang.joinTo
      when '[object Object]'
        newJoinTo = {}
        Object.keys(lang.joinTo).forEach (joinToKey) ->
          newJoinTo[changePath joinToKey] = lang.joinTo[joinToKey]
        lang.joinTo = newJoinTo
  config

# Config items can be a RegExp or a function.
# The function makes universal API to them.
#
# item - RegExp or Function
#
# Returns Function.
normalizeChecker = (item) ->
  switch toString.call(item)
    when '[object RegExp]'
      (string) -> item.test string
    when '[object Function]'
      item
    else
      throw new Error("Config item #{item} is invalid.
Use RegExp or Function.")

# Converts `config.files[...].joinTo` to one format.
# config.files[type].joinTo can be a string, a map of {str: regexp} or a map
# of {str: function}.
#
# Example output:
#
# {
#   javascripts: {'javascripts/app.js': checker},
#   templates: {'javascripts/app.js': checker2}
# }
#
# Returns Object of Object-s.
createJoinConfig = (configFiles) ->
  # Can be used in `reduce` as `array.reduce(listToObj, {})`.
  listToObj = (acc, elem) ->
    acc[elem[0]] = elem[1]
    acc

  types = Object.keys(configFiles)
  result = types
    .map (type) ->
      configFiles[type].joinTo
    .map (joinTo) ->
      if typeof joinTo is 'string'
        object = {}
        object[joinTo] = /.+/
        object
      else
        joinTo
    .map (joinTo, index) ->
      makeChecker = (generatedFilePath) ->
        [generatedFilePath, normalizeChecker(joinTo[generatedFilePath])]
      subConfig = Object.keys(joinTo).map(makeChecker).reduce(listToObj, {})
      [types[index], subConfig]
    .reduce(listToObj, {})
  Object.freeze(result)

indent = (js) ->
  # Emulate negative regexp look-behind a-la (?<!stuff).
  js.replace /(\\)?\n(?!\n)/g, ($0, $1) ->
    if $1 then $0 else '\n  '

exports.cleanModuleName = cleanModuleName = (path) ->
  path
    .replace(new RegExp('\\\\', 'g'), '/')
    .replace(/^app\//, '')

commonJsWrapper = (addSourceURLs = no) -> (fullPath, fileData, isVendor) ->
  sourceURLPath = cleanModuleName fullPath
  path = JSON.stringify sourceURLPath.replace /\.\w+$/, ''

  # JSON-stringify data if sourceURL is enabled.
  data = if addSourceURLs
    JSON.stringify "#{fileData}\n//@ sourceURL=#{sourceURLPath}"
  else
    fileData

  if isVendor
    # Simply execute vendor files.
    if addSourceURLs
      "Function(#{data}).call(this);\n"
    else
      "#{data};\n"
  else
    # Wrap in common.js require definition.
    definition = if addSourceURLs
      "Function('exports, require, module', #{data})"
    else
      "function(exports, require, module) {\n  #{indent data}\n}"
    "window.require.register(#{path}, #{definition});\n"

normalizeWrapper = (typeOrFunction, addSourceURLs) ->
  switch typeOrFunction
    when 'commonjs' then commonJsWrapper addSourceURLs
    when 'amd'
      (fullPath, data) ->
        path = cleanModuleName fullPath
        """
define('#{path}', ['require', 'exports', 'module'], function(require, exports, module) {
  #{indent data}
});
"""
    when false then (path, data) -> "#{data}"
    else
      if typeof typeOrFunction is 'function'
        typeOrFunction
      else
        throw new Error 'config.modules.wrapper should be a function or one of:
"commonjs", "amd", false'

normalizeDefinition = (typeOrFunction) ->
  switch typeOrFunction
    when 'commonjs'
      path = sysPath.join __dirname, '..', 'vendor', 'require_definition.js'
      data = fs.readFileSync(path).toString()
      -> data
    when 'amd', false then -> ''
    else
      if typeof typeOrFunction is 'function'
        typeOrFunction
      else
        throw new Error 'config.modules.definition should be a function
or one of: "commonjs", false'

exports.setConfigDefaults = setConfigDefaults = (config, configPath) ->
  join = (parent, name) =>
    sysPath.join config.paths[parent], name

  joinRoot = (name) ->
    join 'root', name

  paths                = config.paths     ?= {}
  paths.root          ?= config.rootPath  ? '.'
  paths.public        ?= config.buildPath ? joinRoot 'public'

  paths.app           ?= joinRoot 'app'
  paths.generators    ?= joinRoot 'generators'
  paths.test          ?= joinRoot 'test'
  paths.vendor        ?= joinRoot 'vendor'

  paths.assets        ?= join('app', 'assets')

  paths.config        ?= configPath       ? joinRoot 'config'
  paths.packageConfig ?= joinRoot 'package.json'

  conventions          = config.conventions  ?= {}
  conventions.assets  ?= /assets(\/|\\)/
  conventions.ignored ?= paths.ignored ? (path) ->
    sysPath.basename(path)[0] is '_'
  conventions.tests   ?= /[-_]test\.\w+$/
  conventions.vendor  ?= /vendor(\/|\\)/

  config.notifications ?= on
  config.optimize     ?= no

  modules              = config.modules      ?= {}
  modules.wrapper     ?= 'commonjs'
  modules.definition  ?= 'commonjs'
  modules.addSourceURLs ?= no

  config.server       ?= {}
  config.server.base  ?= ''
  config.server.port  ?= 3333
  config.server.run   ?= no
  config

getConfigDeprecations = (config) ->
  messages = []
  warnMoved = (configItem, from, to) ->
    messages.push "config.#{from} moved to config.#{to}" if configItem

  warnMoved config.paths.ignored, 'paths.ignored', 'conventions.ignored'
  warnMoved config.rootPath, 'rootPath', 'paths.root'
  warnMoved config.buildPath, 'buildPath', 'paths.public'

  ensureNotArray = (name) ->
    if Array.isArray config.paths[name]
      messages.push "config.paths.#{name} can't be an array.
Use config.conventions.#{name}"

  ensureNotArray 'assets'
  ensureNotArray 'test'
  ensureNotArray 'vendor'
  messages

normalizeConfig = (config) ->
  normalized = {}
  normalized.join = createJoinConfig config.files
  mod = config.modules
  normalized.modules = {}
  sourceURLs = mod.addSourceURLs and not config.optimize
  normalized.modules.wrapper = normalizeWrapper mod.wrapper, sourceURLs
  normalized.modules.definition = normalizeDefinition mod.definition
  normalized.conventions = {}
  Object.keys(config.conventions).forEach (name) ->
    normalized.conventions[name] = normalizeChecker config.conventions[name]
  config._normalized = Object.freeze normalized
  config

exports.loadConfig = (configPath = 'config', options = {}) ->
  fullPath = sysPath.resolve configPath
  delete require.cache[fullPath]
  try
    originalConfig = require(fullPath).config
  catch error
    throw new Error("couldn\'t load config #{configPath}. #{error}")
  config = extend {}, originalConfig
  setConfigDefaults config, configPath
  deprecations = getConfigDeprecations config
  deprecations.forEach logger.warn if deprecations.length > 0
  recursiveExtend config, options
  replaceSlashes config if os.platform() is 'win32'
  normalizeConfig config
  deepFreeze config
  config
