# context.awk: the context figure of a Claude Code transcript. The one copy, read with awk -f by
# hooks/warn-orchestrator-context.sh, so every reader gives the same number.
# Input: the transcript, or its last 8 MB (tail -c 8388608). The first line of the input may be cut, so it is skipped.
# Output: one line, input_tokens + cache_read_input_tokens + cache_creation_input_tokens of the last assistant line of the
# main chain, which is the prompt the model read on its last call. Sidechain and <synthetic> lines do not count.
# Nothing is printed when there is no such line or it lacks one of the three figures. No transcript text is ever printed.
NR > 1 && index($0, "\"type\":\"assistant\"") && index($0, "\"requestId\":\"req_") && !index($0, "\"isSidechain\":true") && !index($0, "\"model\":\"<synthetic>\"") { last = $0 }
END {
  sum = 0
  n = split("input_tokens cache_read_input_tokens cache_creation_input_tokens", field, " ")
  for (i = 1; i <= n; i++) {
    # The leading quote keeps "input_tokens" from matching inside "cache_read_input_tokens".
    if (!match(last, "\"" field[i] "\":[0-9]+")) exit
    sum += substr(last, RSTART + length(field[i]) + 3, RLENGTH - length(field[i]) - 3)
  }
  print sum
}
