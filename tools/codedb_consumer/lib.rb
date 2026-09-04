$billing_library_loads = ($billing_library_loads || 0) + 1

module Billing
  def self.amount
    42
  end

  def self.source_name
    __FILE__
  end
end
