$codedb_graph_log << "failure"
$codedb_graph_failure_runs = ($codedb_graph_failure_runs || 0) + 1
raise "CodeDB initialization failed" unless $codedb_graph_allow_failure
