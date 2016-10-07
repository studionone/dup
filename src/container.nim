## Docker container management
##
## Author: Josh Girvin <josh@jgirvin.com>
## License: MIT

import os
import osproc
import json
import strutils

import private/types
import database
import config
import util

const dupFile* = ".up.json"
const stateFile* = ".up.state"

## TODO: Move this into "util.nim"
proc checkAndParseDupFile*(dbConf: var DatabaseConfig, conf: var ProjectConfig) {.raises: [].} =
  try:
    if not existsFile(getCurrentDir() / dupFile):
      writeError("No '.up.json' found in current directory")
      quit(255)
    var raw = json.parseFile(getCurrentDir() / dupFile)
    if not raw.hasKey("project"):
      errMissingKey("project", true)
    if not raw.hasKey("db"):
      errMissingKey("db", true)
    # Set our heap-allocated config variables
    dbConf = newDBConfig(raw["db"])
    conf = createProjectConfig(raw, dbConf)
  except DBConfigError:
    writeError("In 'db', " & getCurrentExceptionMsg())
    quit(251)
  except ProjectConfigError:
    writeError("In config, " & getCurrentExceptionMsg())
    quit(252)
  except:
    writeError(getCurrentExceptionMsg(), true)
    quit(250)

## TODO: Move this into "util.nim"
proc checkDockerfile*() {.raises: [].} =
  try:
    if not existsFile(getCurrentDir() / "Dockerfile"):
      writeError("Missing \"Dockerfile\" in current directory")
      quit(254)
  except OSError:
    writeError(getCurrentExceptionMsg(), true)
    quit(1)

proc startMysqlCommand*(conf: ProjectConfig, port: int): string {.raises: [],
                        noSideEffect.} =
  ## Builds the command used to start MySQL database containers
  ## Quotes the configuration passed into the command construction
  result = join([
    "docker run -d",
    "--name", quoteShellPosix(conf.db),
    "--volumes-from", quoteShellPosix(conf.data),
    "-e MYSQL_PASS=" & quoteShellPosix(conf.dbConf.password),
    "-e ON_CREATE_DB=" & quoteShellPosix(conf.dbConf.name),
    "-p", $port & ":3306",
    conf.dbConf.getImageName()
  ], " ")

proc startMysql*(conf: ProjectConfig) =
  writeMsg("Starting MySQL...")
  let
    chosenPort = getAndCheckRandomPort()
    command = startMysqlCommand(conf, chosenPort)
  writeCmd(command)
  let exitCode = execCmd command
  if exitCode != 0:
    writeError("Starting MySQL failed. Check the output above")
    quit(exitCode)
  writeSuccess("MySQL started, and exposed on host port " & $chosenPort)

proc startPostgres*(conf: ProjectConfig) {.raises: [].} =
  writeMsg("Starting Postgres...")
  let
    chosenPort = getAndCheckRandomPort()
    portFragment = $chosenPort & ":5432"
    command = "docker run -d --name " & conf.db & " --volumes-from " & conf.data & " -e POSTGRES_PASSWORD=" & conf.dbConf.password & " -e POSTGRES_DB=" & conf.dbConf.name & " -e POSTGRES_USER=" & conf.dbConf.username & " -p " & portFragment & " " & conf.dbConf.getImageName()
  writeCmd(command)
  let exitCode = execCmd command
  if exitCode != 0:
    writeError("Starting Postgres failed. Check the output above")
    quit(exitCode)
  writeSuccess("Postgres started, and exposed on host port " & $chosenPort)

proc startMongo*(conf: ProjectConfig) {.raises: [].} =
  writeMsg("Starting MongoDB...")
  let
    chosenPort = getAndCheckRandomPort()
    portFragment = $chosenPort & ":27017"
    command = join([
      "docker run -d",
      "--name", conf.db,
      "--volumes-from", conf.data,
      "-p", portFragment,
      conf.dbConf.getImageName
    ], " ")
  writeCmd(command)
  let exitCode = execCmd command
  if exitCode != 0:
    writeError("Starting MongoDB fialed. Check the ouput above")
    quit(exitCode)
  writeSuccess("MongoDB started, and exposed on host port " & $chosenPort)

proc startWeb*(project: string, portMapping="", folderMapping: string, env: Args, hasDB: bool = true) =
  ## TODO: Refactor to leverage the config object instead of raw properties
  writeMsg("Starting web server...")
  var
    hostname = project & ".docker"
  for arg in env:
    if arg.name == "VIRTUAL_HOST":
      hostname = arg.value
  let
    link = if hasDB: "--link " & project & "-db:db " else: ""
    folder = if folderMapping == "": "-v $PWD/code:/var/www " else: "-v $PWD/" & folderMapping & " "
    port = if portMapping == "": " " else: "-p " & portMapping & " "
    command = "docker run -d -h " & hostname & " --name " & project & "-web " & port & $env & " " & folder & link & " -e TERM=xterm-256color -e VIRTUAL_HOST=" & hostname & " " & project & ":latest"
  writeCmd(command)
  let exitCode = execCmd command
  if exitCode != 0:
    writeError("Starting web server failed. Check the output above")

proc inspectContainer*(containerName: string): JsonNode =
  try:
    let (output, exitCode) = execCmdEx("docker inspect " & containerName, {poUsePath})
    if exitCode != 0:
      raise newException(IOError, "docker-inspect failed")
    result = parseJson(output)
  except:
    result = parseJson("[]")

## Checks the result of "docker inspect <container-name>" to see if it's running
## Assumes that the first object in the array returned by "inspect" is the
## container in question. Uses `return` to short-circuit the proc as needed
proc isContainerRunning*(inspectNode: JsonNode): bool =
  if inspectNode.len == 0:
    return false
  let running = inspectNode[0]{"State", "Running"}
  if running == nil:
    return false
  return running.bval

proc doesContainerExist*(inspectNode: JsonNode): bool =
  result = true
  if inspectNode.len == 0:
    result = false

proc hasDataContainerBeenBuilt*(conf: ProjectConfig): bool {.raises: [].} =
  ## Inspects the <project>-data container to check existance
  try:
    let
      dataContainer = inspectContainer(conf.data)
    result = doesContainerExist(dataContainer)
  except:
    writeError(getCurrentExceptionMsg(), true)
    quit(1)
