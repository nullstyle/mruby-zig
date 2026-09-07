class << Legacy
  alias copied bump
end
class NativeAudit
  def self.run
    begin
      Legacy.copied
    rescue
      "rescued"
    end
  end

  def self.send_run
    begin
      Legacy.__send__(:bump)
    rescue
      "rescued"
    end
  end
end
