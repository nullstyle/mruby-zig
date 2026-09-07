# The host owns transactions, durable identities and deferred delivery.
# These are the only two domain effects used by the application.
class Inventory
  def self.apply(state, input)
    quantity = input["quantity"]
    mode = input["mode"]
    quantity = "two" if mode == "invalid_argument"
    quantity -= 1 if mode == "mismatched_request"
    next_state = {"attempts" => state["attempts"] + 1}
    begin
      reservation = Effect.perform(Stock.reserve(input["sku"], quantity))
      reservation["id"] = "0" * 64 if mode == "forged_notification"
      reservation["remaining"] += 1 if mode == "mismatched_reservation"
      intent = Effect.perform(Notifications.reservation_created(reservation))
      Effect.perform(Notifications.reservation_created(reservation)) if mode == "duplicate_notification"
      raise "failure after staging inventory and notification" if input["fail"]
      result = {"status" => "reserved", "reservation" => reservation, "intent" => intent}
    rescue Effect::Rejected => rejection
      raise rejection unless rejection.code == "OutOfStock"
      result = {"status" => "rejected", "code" => rejection.code}
    end
    result["status"] = "invalid" if mode == "invalid_turn_result"
    next_state["attempts"] = -1 if mode == "invalid_next_state"
    next_state["attempts"] += 1 if mode == "mismatched_next_state"
    result["reservation"]["remaining"] += 1 if mode == "invalid_reserved_result"
    result = {"status" => "rejected", "code" => "OutOfStock"} if mode == "rejected_after_staging"
    [result, next_state]
  end
end
