# Hardware-Accelerated Stochastic Market Microstructure Simulator - ECE 5760 Final Project

___

## Packet Format

32-bit order packet written into the arbiter FIFO:

| Bits      | Field        | Description                                           |
|-----------|--------------|-------------------------------------------------------|
| `[31]`    | `side`       | `0` = buy, `1` = sell                                 |
| `[30]`    | `order_type` | `0` = limit, `1` = market                             |
| `[29:28]` | `agent_type` | `00` = noise, `01` = mm, `10` = momentum, `11` = value|
| `[27:25]` | `reserved`   | `0`                                                   |
| `[24:16]` | `price`      | 9-bit tick index (0-479, direct LOB address)          |
| `[15:0]`  | `volume`     | unsigned 16-bit                                       |
