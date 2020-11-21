import os

switch "path", getCurrentCompilerExe().parentDir.parentDir
--gc:markAndSweep

hint "XDeclaredButNotUsed", false

--path:"$lib/packages/docutils"

--define:useStdoutAsStdmsg
--define:nimsuggest
--define:nimcore

# die when nimsuggest uses more than 4GB:
when defined(cpu32):
  switch "define", "nimMaxHeap=2000"
else:
  switch "define", "nimMaxHeap=4000"

--threads:on
warning "Spacing", false # The JSON schema macro uses a syntax similar to TypeScript
warning "CaseTransition", false
--define:nimOldCaseObjects