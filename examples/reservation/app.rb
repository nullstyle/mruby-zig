class ReservationFlow
  def self.apply(state, input)
    quantity = input["quantity"]
    quantity = "two" if input["mode"] == "invalid_argument"
    attempts = state["attempts"] + 1

    begin
      reservation = Effect.perform(Stock.reserve(input["sku"], quantity))
      Effect.perform(Notifications.reservation_created(reservation))
      raise "aborted after staging reservation" if input["mode"] == "raise"
      result = {"status" => "reserved", "reservation" => reservation}
      next_state = {"attempts" => attempts, "reservations" => state["reservations"] + 1}
    rescue Effect::Rejected => error
      raise error unless error.code == "OutOfStock"
      result = {"status" => "out_of_stock", "code" => error.code}
      next_state = {"attempts" => attempts, "reservations" => state["reservations"]}
    end

    result["status"] = "invalid" if input["mode"] == "invalid_turn_result"
    next_state["reservations"] = -1 if input["mode"] == "invalid_next_state"
    [result, next_state]
  end
end
