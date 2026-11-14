// /go/bigcartel: a single item goes straight to the brand's Big Cartel cart,
// in this tab rather than a new one.
const auto = document.querySelector("form[data-auto]");
if (auto) {
  auto.target = "_self";
  auto.submit();
}
