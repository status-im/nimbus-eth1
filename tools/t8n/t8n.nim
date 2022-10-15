import
  "."/[config, transition, types]

template wrapException(body) =
  when wrapExceptionEnabled:
    try:
      body
    except T8NError as e:
      stderr.writeLine(e.msg)
      quit(e.exitCode.int)
    except:
      let e = getCurrentException()
      stderr.writeLine($e.name & " : " & e.msg)
      quit(QuitFailure)
  else:
    body

proc main() =
  wrapException:
    let conf = T8NConf.init()
    var ctx = TransContext()
    ctx.transitionAction(conf)

main()
