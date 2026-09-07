# DB and Outbox methods construct inert requests. Only Effect.perform crosses
# the host boundary. Local Ruby computation and mutation need no annotation.
class Inventory
  def self.reserve(sku, quantity)
    rows = Effect.perform(DB.rows("SELECT quantity FROM stock WHERE sku = ?", [sku]))
    available = rows[0][0]
    begin
      Effect.perform(DB.execute("UPDATE stock SET quantity = quantity - ? WHERE sku = ? AND quantity >= ?", [quantity, sku, quantity]))
    rescue Effect::Rejected => rejection
      return "unavailable:#{sku}:#{available}:#{rejection.code}"
    end
    Effect.perform(DB.execute("INSERT INTO reservations(sku, quantity) VALUES (?, ?)", [sku, quantity]))
    receipt = Effect.perform(Outbox.enqueue("reservations", "#{sku}:#{quantity}"))
    "reserved:#{sku}:#{quantity}:#{available - quantity}:#{receipt}"
  end

  def self.inspect_stock(sku, attempt_write)
    rows = Effect.perform(DB.rows("SELECT quantity FROM stock WHERE sku = ?", [sku]))
    if attempt_write
      Effect.perform(DB.execute("UPDATE stock SET quantity = quantity - ? WHERE sku = ? AND quantity >= ?", [1, sku, 1]))
    end
    "stock:#{sku}:#{rows[0][0]}"
  end

  def self.reserve_then_fail(sku, quantity)
    reserve(sku, quantity)
    raise "failure after preparing a reservation"
  end

  def self.read_sql(sql)
    Effect.perform(DB.rows(sql, []))
  end

  def self.write_sql(sql)
    Effect.perform(DB.execute(sql, []))
  end
end
