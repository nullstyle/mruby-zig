class CodedbJob
  def self.run(n)
    n * 2
  end
end
$codedb_dispatch = CodedbJob.run(21)
