
template raisesAssertion*(exp: untyped): untyped =
  ## Checks the expression passed raises an assertion
  block:
    var asserted = false
    try:
      exp
    except AssertionDefect:
      asserted = true
    doAssert asserted

when isMainModule:
  block:
    raisesAssertion(doAssert false)
    var raised = false
    try:
      raisesAssertion(doAssert true)
    except AssertionDefect:
      raised = true
    doAssert raised

  echo "ok"