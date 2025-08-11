# Exponential bonding curve

- Slow price growth at the beggning
- Explosive growth gettign closer to graduation


### Definitions

- $T$: token total supply
- $p(x)$: Price at circulating supply *x*
- $M(x)$: Market cap at circulating supply *x*




Price for a given circulating  supply, x:

- $p(x) = a e^{bx}$
  
Eth reserves accumulated at a price X

- $R(x) = \int{p(x)dx}$
- $R(x) = a/b * e^{bx} + c$ 

Relationship betwen price and reserves:

- $R(x) = (1 / b) * p(x) + x$

Token market cap as function of price:

- $M(x) = T * p(x)$


### Constraints
1. At graduation, the eth reserves:  
 
    $R(g) = 40 Eth = 40e18$

2. At graduation, the Market cap should be 4 times the liquidity

    $M(g) = 4 L(g)$

    $T . p(g) = 4 L(g)$

3. At graduatoin, the total liquidity added will be doube of the ETH reserves

    $L(g) = 2 R(g)$


### Solution

 - $M(g) = 4 L(g)$
 - $L(g) = 2 R(g)$ = 80e18 eth
 - $T . p(g) = 4 L(g)$







$(a/b) . e^{bx} + c = 40e18$


$x = (1/b) * ln(b . (40e18 - c) / a)$
$x = (1/b) * ln(b . 40e18)$

b = 1
$x = ln(40e18) = 45.135
