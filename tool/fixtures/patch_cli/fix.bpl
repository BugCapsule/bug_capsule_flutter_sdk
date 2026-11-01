// The fix: percent applies as a percentage, rounded half-even, capped at 50%,
// and bulk lines of 10+ units get 5% off first.
module pricing.coupon;

type Line = { sku: string, qty: int, unitPrice: dec<2> };
type Input = { lines: Line[], couponPercent: int };
type Output = { subtotal: dec<2>, discount: dec<2>, total: dec<2>, label: string };

function lineTotal(l: Line): dec<2> {
  const gross = l.unitPrice * l.qty;
  if (l.qty >= 10) {
    return round(gross * 0.95, 2, "half_even");
  }
  return gross;
}

export function compute(input: Input): Output {
  const subtotal = input.lines.fold(0.00, (acc, l) => acc + lineTotal(l));
  const percent = input.couponPercent > 50 ? 50 : input.couponPercent;
  const discount = div(subtotal * percent, 100, 2, "half_even");
  return {
    subtotal,
    discount,
    total: subtotal - discount,
    label: "PATCHED " + str(percent) + "%",
  };
}
