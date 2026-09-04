# Host-supplied line items are [unit price in cents, quantity] pairs.
# Keep money integral and produce an inert result suitable for a capsule.
subtotal = 0
$invoice_items.each do |price, quantity|
  raise ArgumentError, "invalid line item" unless price >= 0 && quantity > 0
  subtotal += price * quantity
end
discount = subtotal >= $invoice_discount_threshold ? subtotal / $invoice_discount_divisor : 0
$invoice_jobs += 1
[subtotal, discount, subtotal - discount, __FILE__]
