module IntegerBoundaries
  def self.sort_extremes(minimum, maximum)
    [maximum, minimum, 0, -1, 1, maximum].sort
  end
  def self.binary_minimum(minimum)
    minimum.to_s(2)
  end
end
