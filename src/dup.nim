let doc = """
Declaratively define and run stateful Docker containers for web development.

Usage:
  dup up
  dup down
  dup init
  dup status
  dup build [--no-cache]
  dup (-h | --help)
  dup --version
"""

import os
import osproc
import strutils
import json
import docopt

let args = docopt(doc, version = "Docker Up 0.1")

const dupFile = ".up.json"
const stateFile = ".up.state"

proc checkDupFile(): JsonNode =
  if not existsFile(getCurrentDir() / dupFile):
    echo("Error: Missing \".up.json\" in current directory.")
    quit(255)

  let conf = json.parseFile(getCurrentDir() / dupFile)
  if not conf.hasKey("project"):
    echo("Error: Your \".up.json\" file is missing the \"project\" key.")
    quit(252)
  if not conf.hasKey("db"):
    echo("Error: Your \".up.json\" file is missing the \"db\" key.")
    quit(252)
  if not conf["db"].hasKey("type"):
    echo("Error: Missing \"type\" key in \"db\".")
  return conf

proc checkDockerfile() =
  if not existsFile(getCurrentDir() / "Dockerfile"):
    echo("Error: Missing \"Dockerfile\" in current directory.")
    quit(254)

proc checkStatefile(): bool =
  return existsFile(getCurrentDir() / stateFile)

proc buildStatefile() =
  open(getCurrentDir() / stateFile, fmWrite).close()

# Check our Dockerfile and .up.json files exist
checkDockerfile()
let config = checkDupFile()


###
# Command definitions
##

if args["init"]:
  if checkStateFile():
    echo("Error: Docker Up has already been initalised.")
    echo("To rebuild the data-volume container, remove the " & config["project"].getStr() & "-data container, and delete the .up.state file.")
    quit(253)

  case config["db"]["type"].getStr():
  of "mysql":
    echo("Initialising MySQL volume-only container...")
    let command = "docker run -d -v /var/lib/mysql --name " & config["project"].getStr() & "-data --entrypoint /bin/echo tutum/mysql"
    let (output, exitCode) = execCmdEx command

    case exitCode:
    of 0:
      buildStateFile()
      echo("Done.")
      quit(0)
    else:
      echo("An error occurred!\n\nSee the following for details:\n" & output)
      quit(exitCode)

  else:
    echo("Error: Invalid database type specified in config.")
    quit(252)
  quit(0)

if args["up"]:
  if not checkStatefile():
    quit(252)
  quit(0)

if args["down"]:
  if not checkStatefile():
    quit(252)
  quit(0)
