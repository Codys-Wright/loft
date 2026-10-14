### Elephant Calculator (Loft)

Spotlight's calculator: math, unit and currency conversion, time zones. Enter copies the result.

- `2^10`, `sqrt 2`, `15% of 80`, `20% off 59.99`
- `5 km to mi`, `72f to c`, `1 GiB in MB`, `5 ft 3 in to cm`, `100 kph in mph`
- `100 usd in eur`, `$20 to ¥`, `0.5 btc to usd`
- `3pm PT in Berlin`, `9:30 tokyo to london`, `time in Sydney`, `now in utc+5:30`

Math, units and currencies are libqalculate's (`qalc`, run with its own config, so your
qalc settings are untouched); queries are normalized first ("in"/"as"/"→" mean "to", `72f`
is °F, no mixed units) and anything qalc only half understands is dropped. Time zones are
handled here (city names from the tz database, plus PT/ET/CET/IST… and UTC±h).

Currency rates are qalc's: the ones it ships with, or the last download. Downloading them
(`qalc -e`, once a day) is opt-in: `"currencyRates": true` in the settings file
(Settings → Spotlight → Update currency rates daily).

#### Files

- `settings`: spotlight.json (`currencyRates`), shared with the bangs provider.
