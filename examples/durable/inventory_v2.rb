# Application version inventory/v2. Identical effect sites to v1; the next
# state now records how many reservation attempts were rejected, which v1
# never tracked. This file is bundled separately from inventory.rb.
class Inventory
  def self.apply(state, input)
    quantity = input["quantity"]
    next_state = {"attempts" => state["attempts"] + 1, "rejections" => state["rejections"]}
    begin
      reservation = Effect.perform(Stock.reserve(input["sku"], quantity))
      intent = Effect.perform(Notifications.reservation_created(reservation))
      raise "failure after staging inventory and notification" if input["fail"]
      result = {"status" => "reserved", "reservation" => reservation, "intent" => intent}
    rescue Effect::Rejected => rejection
      raise rejection unless rejection.code == "OutOfStock"
      next_state["rejections"] += 1
      result = {"status" => "rejected", "code" => rejection.code}
    end
    [result, next_state]
  end
end
