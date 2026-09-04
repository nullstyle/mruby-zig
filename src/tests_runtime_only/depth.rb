recur = nil
recur = -> { recur.call }
recur.call
