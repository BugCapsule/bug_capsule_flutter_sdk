// Base behaviour: the shipped fallback does the same arithmetic.
module pricing.coupon;

type Line = { sku: string, qty: int, unitPrice: dec<2> };
type Input = { lines: Line[], couponPercent: int };
type Output = { subtotal: dec<2>, discount: dec<2>, total: dec<2>, label: string };

function lineTotal(l: Line): dec<2> {
  return l.unitPrice * l.qty;
}

export function compute(input: Input): Output {
  const subtotal = input.lines.fold(0.00, (acc, l) => acc + lineTotal(l));
  const discount = round(subtotal * input.couponPercent, 2, "down");
  return {
    subtotal,
    discount: discount,
    total: subtotal - discount,
    label: "BASE " + str(input.couponPercent) + "%",
  };
}
