"""
Tokenomics model: mint.club bonding curve + Uniswap V4 full-range pool + GlueHook pot + RoyaltyRouter.

Units: token T (18 dec, modelled as floats in whole tokens), quote E (ETH). Curve prices are E per T.
Mechanics mirror the contracts:
  curve   : step prices, mint pays price+royalty, burn refunds price−royalty; 80% of royalty → creator (router), 20% → protocol
  pool    : full-range concentrated liquidity ≈ constant product with liquidity L; fee f on input; LP fees split per ProgramConfig
  pot     : PUMP on buys: spend = 0.8·min(pot, f·E_depth, user_in); SHIELD on sells: absorb at the pool's own execution price
  compound: pot output (T) → carryMain; ETH-side LP fees × compoundShare → carrySecondary; paired into L at the live price
  router  : royalties swept periodically; DAO cut + keeper bounty in E, the rest donated to the pot
  arb     : keeps the pool inside [curve burn price, curve mint price] (pays curve royalties while doing so)
"""
from __future__ import annotations
import math, random
from dataclasses import dataclass, field

# ───────────────────────────── mint.club curve ─────────────────────────────
@dataclass
class Curve:
    steps: list[tuple[float, float]]           # (range_to, price E/T)
    mint_royalty: float = 0.03
    burn_royalty: float = 0.03
    supply: float = 0.0
    reserve: float = 0.0
    protocol_income: float = 0.0
    creator_pending: float = 0.0               # unclaimed royalty owed to the creator (router)

    def price(self, s: float | None = None) -> float:
        s = self.supply if s is None else s
        for r, p in self.steps:
            if s < r: return p
        return self.steps[-1][1]

    def _integral(self, s0: float, s1: float) -> float:
        """E to move supply s0→s1 along the steps (s1 > s0)."""
        cost, s = 0.0, s0
        for r, p in self.steps:
            if r <= s: continue
            take = min(r, s1) - s
            if take <= 0: break
            cost += take * p; s += take
            if s >= s1: break
        return cost

    def mint_cost(self, n: float) -> tuple[float, float]:
        base = self._integral(self.supply, self.supply + n)
        roy = base * self.mint_royalty
        return base + roy, roy

    def mint(self, n: float) -> float:
        cost, roy = self.mint_cost(n)
        self.supply += n; self.reserve += cost - roy
        self._royalty(roy); return cost

    def burn_refund(self, n: float) -> tuple[float, float]:
        base = self._integral(self.supply - n, self.supply)
        roy = base * self.burn_royalty
        return base - roy, roy

    def burn(self, n: float) -> float:
        refund, roy = self.burn_refund(n)
        self.supply -= n; self.reserve -= refund + roy
        self._royalty(roy); return refund

    def _royalty(self, roy: float):
        self.protocol_income += roy * 0.2
        self.creator_pending += roy * 0.8

    def tokens_for(self, e: float) -> float:
        """Tokens mintable with E (incl. royalty), by bisection."""
        lo, hi = 0.0, 1.0
        while self.mint_cost(hi)[0] < e: hi *= 2
        for _ in range(60):
            mid = (lo + hi) / 2
            (lo, hi) = (mid, hi) if self.mint_cost(mid)[0] < e else (lo, mid)
        return lo

# ───────────────────────────── V4 full-range pool ─────────────────────────────
@dataclass
class Pool:
    L: float                                   # liquidity (sqrt(x·y) for full range)
    sqrt_p: float                              # sqrt(E per T)
    fee: float = 0.003
    fees_t: float = 0.0; fees_e: float = 0.0   # pending LP fees by side (gross)
    @property
    def price(self): return self.sqrt_p ** 2
    @property
    def t_reserve(self): return self.L / self.sqrt_p
    @property
    def e_reserve(self): return self.L * self.sqrt_p

    def quote_buy(self, e_in: float) -> float:
        """T out for E in (fee on input), no state change."""
        e_net = e_in * (1 - self.fee)
        new_sqrt = self.sqrt_p + e_net / self.L
        return self.L * (1 / self.sqrt_p - 1 / new_sqrt)

    def quote_sell(self, t_in: float) -> float:
        t_net = t_in * (1 - self.fee)
        new_inv = 1 / self.sqrt_p + t_net / self.L
        return self.L * (self.sqrt_p - 1 / new_inv)

    def buy(self, e_in: float) -> float:
        out = self.quote_buy(e_in); self.fees_e += e_in * self.fee
        self.sqrt_p += e_in * (1 - self.fee) / self.L
        return out

    def sell(self, t_in: float) -> float:
        out = self.quote_sell(t_in); self.fees_t += t_in * self.fee
        self.sqrt_p = 1 / (1 / self.sqrt_p + t_in * (1 - self.fee) / self.L)
        return out

    def add(self, t: float, e: float) -> tuple[float, float]:
        """Mint full-range liquidity from (t, e); the binding side caps. Returns used (t, e)."""
        l = min(t * self.sqrt_p, e / self.sqrt_p)
        if l <= 0: return 0.0, 0.0
        self.L += l
        return l / self.sqrt_p, l * self.sqrt_p

    def e_for_price(self, target: float) -> float:
        """E to buy to reach `target` price (>current); negative → T to sell (returned as E-equivalent sign)."""
        new_sqrt = math.sqrt(target)
        return (new_sqrt - self.sqrt_p) * self.L / (1 - self.fee)

    def t_for_price(self, target: float) -> float:
        new_sqrt = math.sqrt(target)
        return (1 / new_sqrt - 1 / self.sqrt_p) * self.L / (1 - self.fee)

# ───────────────────────────── GlueHook pot + program ─────────────────────────────
@dataclass
class Hook:
    pool: Pool
    enabled: bool = True
    pot: float = 0.0                           # E
    carry_t: float = 0.0; carry_e: float = 0.0
    compound_share: float = 0.5; buyback_share: float = 0.5
    fee_recipient_t: float = 0.0; fee_recipient_e: float = 0.0
    pot_out_mode: str = "compound"             # compound | burn | recycle
    burned_t: float = 0.0
    recycle_t: float = 0.0                     # tokens held by a recycler recipient, awaiting a curve burn
    recycled_e: float = 0.0
    pumped_e: float = 0.0; shielded_e: float = 0.0; shielded_t: float = 0.0

    def donate(self, e: float): self.pot += e

    def _pot_output(self, t: float):
        if self.pot_out_mode == "burn": self.burned_t += t
        elif self.pot_out_mode == "recycle": self.recycle_t += t
        else: self.carry_t += t

    def recycle(self, curve: "Curve"):
        """Recycler recipient: burn held tokens on the curve, donate the refund. Permissionless on-chain."""
        if self.recycle_t <= 0: return
        refund = curve.burn(self.recycle_t); self.recycle_t = 0.0
        self.pot += refund; self.recycled_e += refund

    def on_buy(self, e_in: float) -> float:
        """Trader buys with e_in; returns T delivered to trader. Pump runs after."""
        out = self.pool.buy(e_in)
        if self.enabled and self.pot > 0:
            spend = 0.8 * min(self.pot, self.pool.fee * self.pool.e_reserve, e_in)
            if spend > 0:
                got = self.pool.buy(spend); self.pot -= spend; self.pumped_e += spend
                self._pot_output(got)
        self.harvest(); return out

    def on_sell(self, t_in: float) -> float:
        """Trader sells t_in; shield absorbs what the pot can afford at the pool's own price."""
        paid = 0.0
        if self.enabled and self.pot > 0:
            full = self.pool.quote_sell(t_in)
            if full <= self.pot:
                absorb_t, absorb_e = t_in, full
            else:                              # absorb the largest slice the pot can pay for (bisection)
                lo, hi = 0.0, t_in
                for _ in range(40):
                    mid = (lo + hi) / 2
                    lo, hi = (mid, hi) if self.pool.quote_sell(mid) <= self.pot else (lo, mid)
                absorb_t = lo; absorb_e = self.pool.quote_sell(absorb_t)
            self.pot -= absorb_e; paid += absorb_e; t_in -= absorb_t
            self.shielded_e += absorb_e; self.shielded_t += absorb_t
            self._pot_output(absorb_t)
        if t_in > 0: paid += self.pool.sell(t_in)
        self.harvest(); return paid

    fees_seen_e: float = 0.0                   # gross LP fees, E-equivalent (token side valued at pool price)

    def harvest(self):
        p = self.pool
        ft, fe = p.fees_t, p.fees_e
        if ft == 0 and fe == 0 and self.carry_t == 0 and self.carry_e == 0: return
        self.fees_seen_e += fe + ft * p.price
        p.fees_t = p.fees_e = 0.0
        if not self.enabled:                   # plain LP: all fees to the owner
            self.fee_recipient_t += ft; self.fee_recipient_e += fe; return
        self.pot += fe * self.buyback_share
        self.fee_recipient_e += fe * (1 - self.compound_share - self.buyback_share)
        self.fee_recipient_t += ft * (1 - self.compound_share)
        bt, be = self.carry_t + ft * self.compound_share, self.carry_e + fe * self.compound_share
        ut, ue = p.add(bt, be)
        self.carry_t, self.carry_e = bt - ut, be - ue

# ───────────────────────────── Router ─────────────────────────────
@dataclass
class Router:
    hook: Hook
    mode: str = "pot"                          # pot | lp
    dao_bps: int = 1000; bounty_bps: int = 50
    dao_income: float = 0.0; keeper_income: float = 0.0; donated: float = 0.0; lp_e: float = 0.0
    def sweep(self, curve: Curve):
        amt = curve.creator_pending; curve.creator_pending = 0.0
        if amt <= 0: return
        dao = amt * self.dao_bps / 10_000; bounty = amt * self.bounty_bps / 10_000
        self.dao_income += dao; self.keeper_income += bounty
        rest = amt - dao - bounty; self.donated += rest
        if self.mode == "pot": self.hook.donate(rest); return
        # LP mode (what the contracts do): buy the token side ON THE CURVE with net·(1+r)/(2+r) — its royalty
        # accrues right back here — pair with the rest, mint locked full-range liquidity; leftovers carry.
        r = curve.mint_royalty
        budget = rest * (1 + r) / (2 + 0.2 * r)
        tk = curve.tokens_for(budget); curve.mint(tk)
        refund = curve.creator_pending; curve.creator_pending = 0.0     # the mint's own royalty, claimed in the same sweep
        ut, ue = self.hook.pool.add(tk + self.hook.carry_t, rest - budget + refund + self.hook.carry_e)
        self.lp_e += ue + ut * self.hook.pool.price
        self.hook.carry_t = tk + self.hook.carry_t - ut; self.hook.carry_e = rest - budget + refund + self.hook.carry_e - ue
        self.hook.harvest()

# ───────────────────────────── World ─────────────────────────────
@dataclass
class World:
    curve: Curve; pool: Pool; hook: Hook; router: Router | None
    creator_income: float = 0.0                # baseline: royalties kept by the creator
    arb_profit: float = 0.0
    arb_volume_e: float = 0.0
    sweep_every: int = 25
    log: list = field(default_factory=list)
    t: int = 0
    sell_real: list = field(default_factory=list)   # E received / (tokens × curve price) for trader sells
    buy_real: list = field(default_factory=list)    # tokens received × curve price / E paid for trader buys
    pool_share: int = 0                              # trader trades that chose the pool
    pool_bias: float = 0.0                           # share of traders who use the pool regardless of price (aggregators, habit)
    roy_trader: float = 0.0                          # creator royalty generated by traders minting/burning on the curve
    roy_arb: float = 0.0                             # …by arbitrageurs keeping the pool inside the band
    lp_fees_e: float = 0.0                           # gross LP fees, E-equivalent, earned by the program position
    venue: str = "best"                              # UI routing policy: best (quote both, take better) | pool | curve | split (on-chain aggregator: pool up to the curve price, rest on the curve)
    graduate_at: float = 0.0                         # pump.fun analog: supply at which the curve closes and its reserve migrates to the pool (0 = never)
    graduated: bool = False
    buy_mid: list = field(default_factory=list)      # tokens received × pool mid before trade / E paid (venue-neutral execution)
    sell_mid: list = field(default_factory=list)     # E received / (tokens × pool mid before trade)

    # traders pick the better venue for their size
    def _use_pool(self, better_pool: bool, rng_val: float) -> bool:
        if self.graduated or self.venue == "pool": return True
        if self.venue == "curve": return False
        return better_pool or rng_val < self.pool_bias

    def crossover_buy(self) -> float:
        """Smallest buy (E) at which the curve delivers ≥ tokens than the pool. inf = pool always wins, 0 = curve always wins."""
        if self.graduated: return math.inf
        f = lambda e: self.pool.quote_buy(e) - self.curve.tokens_for(e)
        if f(1e-6) <= 0: return 0.0
        lo, hi = 1e-6, 1e-3
        while f(hi) > 0:
            hi *= 2
            if hi > 1e4: return math.inf
        for _ in range(40):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if f(mid) > 0 else (lo, mid)
        return hi

    def crossover_sell(self) -> float:
        """Smallest sell (in E at pool mid) at which the curve pays ≥ the pool."""
        if self.graduated: return math.inf
        f = lambda t: self.pool.quote_sell(t) - self.curve.burn_refund(t)[0]
        cap = self.curve.supply * 0.5
        if f(1e-6) <= 0: return 0.0
        lo, hi = 1e-6, 1e-3 / self.pool.price
        while f(hi) > 0:
            hi *= 2
            if hi > cap: return math.inf
        for _ in range(40):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if f(mid) > 0 else (lo, mid)
        return hi * self.pool.price

    def trader_buy(self, e: float) -> float:
        via_pool = self.pool.quote_buy(e)
        via_curve = self.curve.tokens_for(e)
        ref = self.curve.price(); mid = self.pool.price
        before = self.curve.creator_pending
        if self.venue == "split" and not self.graduated:
            # fill the pool until its marginal price reaches the curve's mint price (incl. royalty), then mint the rest
            e_pool = min(e, max(0.0, self.pool.e_for_price(ref * (1 + self.curve.mint_royalty))))
            got = self.hook.on_buy(e_pool) if e_pool > 0 else 0.0
            if e - e_pool > 1e-12: n = self.curve.tokens_for(e - e_pool); self.curve.mint(n); got += n
            if e_pool > 0: self.pool_share += 1
        elif self._use_pool(via_pool >= via_curve, random.random()): got = self.hook.on_buy(e); self.pool_share += 1
        else: self.curve.mint(via_curve); got = via_curve
        self.roy_trader += self.curve.creator_pending - before
        if ref > 0: self.buy_real.append(got * ref / e)
        self.buy_mid.append(got * mid / e)
        return got

    def trader_sell(self, tk: float) -> float:
        via_pool = self.pool.quote_sell(tk)
        via_curve = self.curve.burn_refund(tk)[0]
        ref = self.curve.price(); mid = self.pool.price
        before = self.curve.creator_pending
        if self.venue == "split" and not self.graduated:
            floor = self.curve.burn_refund(1e-9)[0] / 1e-9          # curve's marginal burn price after royalty
            t_pool = min(tk, max(0.0, self.pool.t_for_price(floor)))
            got = self.hook.on_sell(t_pool) if t_pool > 0 else 0.0
            if tk - t_pool > 1e-12: got += self.curve.burn(tk - t_pool)
            if t_pool > 0: self.pool_share += 1
        elif self._use_pool(via_pool >= via_curve, random.random()): got = self.hook.on_sell(tk); self.pool_share += 1
        else: got = self.curve.burn(tk)
        self.roy_trader += self.curve.creator_pending - before
        if ref > 0: self.sell_real.append(got / (tk * ref))
        self.sell_mid.append(got / (tk * mid))
        return got

    def arbitrage(self):
        """Greedy chunked arbitrage between the curve and the pool. Each chunk is executed only if it is
        profitable on its own, so step jumps on the curve are respected. Arb trades go through the hook
        exactly like anyone else's (their pool sells hit the shield, their pool buys fire the pump)."""
        if self.graduated: return
        before = self.curve.creator_pending
        self._arb_loop()
        self.roy_arb += self.curve.creator_pending - before

    def _arb_loop(self):
        for _ in range(60):
            chunk_t = max(self.pool.t_reserve * 0.01, 1e-9)
            # pool above curve: mint on the curve, sell into the pool
            cost = self.curve.mint_cost(chunk_t)[0]
            rev = self.pool.quote_sell(chunk_t)
            if rev > cost * 1.0005:
                self.curve.mint(chunk_t); got = self.hook.on_sell(chunk_t)
                self.arb_profit += got - cost; self.arb_volume_e += got; continue
            # pool below curve: buy from the pool, burn on the curve
            chunk_e = self.pool.e_reserve * 0.01
            tk = self.pool.quote_buy(chunk_e)
            if tk <= self.curve.supply:
                refund = self.curve.burn_refund(tk)[0]
                if refund > chunk_e * 1.0005:
                    got_t = self.hook.on_buy(chunk_e); refund = self.curve.burn(got_t)
                    self.arb_profit += refund - chunk_e; self.arb_volume_e += chunk_e; continue
            break

    def graduate(self):
        """pump.fun-style migration: the curve closes; its whole reserve plus a matching token allocation become
        the pool's liquidity at the curve price. No curve means no royalty and no arbitrage anchor afterwards."""
        p = self.curve.price(); e = self.curve.reserve
        self.pool.sqrt_p = math.sqrt(p); self.pool.L = 0.0
        self.pool.add(e / p, e)
        self.curve.reserve = 0.0; self.curve.supply += e / p
        self.graduated = True

    def step(self, action: str, size: float):
        if action == "buy": self.trader_buy(size)
        else: self.trader_sell(size)
        if self.graduate_at and not self.graduated and self.curve.supply >= self.graduate_at: self.graduate()
        self.arbitrage()
        self.t += 1
        if self.router and self.t % self.sweep_every == 0:
            self.hook.recycle(self.curve); self.router.sweep(self.curve)
        if not self.router:
            self.creator_income += self.curve.creator_pending; self.curve.creator_pending = 0.0
        self.log.append(dict(t=self.t, pool_price=self.pool.price, curve_price=self.curve.price(),
                             L=self.pool.L, pot=self.hook.pot, carry_t=self.hook.carry_t,
                             supply=self.curve.supply, arb=self.arb_profit))

# ───────────────────────────── Scenario builder ─────────────────────────────
STEPS = [(1_000, 0.0), (100_000, 1e-4), (1_000_000, 1e-3)]

def build(mode: str, seed_t=4_000.0, seed_e=0.4, royalty=0.03, compound_share=0.5, buyback_share=0.5, pool_bias=0.0,
          venue="best", graduate_at=0.0) -> World:
    """mode: baseline | compound | recycle | lp | graduate (pump.fun analog: curve-only until `graduate_at`, then pool-only)"""
    if mode == "graduate":
        curve = Curve(STEPS, mint_royalty=royalty, burn_royalty=royalty)
        curve.supply = 1_000.0; curve.mint(5_000.0); p0 = curve.price()
        pool = Pool(L=1e-9, sqrt_p=math.sqrt(p0))                 # no pool exists before graduation
        hook = Hook(pool, enabled=False)
        w = World(curve, pool, hook, None); w.venue = "curve"; w.graduate_at = graduate_at
        w.creator_income += curve.creator_pending; curve.creator_pending = 0.0
        return w
    curve = Curve(STEPS, mint_royalty=royalty, burn_royalty=royalty)
    curve.supply = 1_000.0                                  # free range to creator
    cost = curve.mint(5_000.0)                              # seed mint, royalty already accrues
    p0 = curve.price()
    pool = Pool(L=min(seed_t * math.sqrt(p0), seed_e / math.sqrt(p0)), sqrt_p=math.sqrt(p0))
    hook = Hook(pool, enabled=(mode != "baseline"), pot_out_mode=(mode if mode in ("burn", "recycle") else "compound"),
                compound_share=(1.0 if mode == "lp" else compound_share), buyback_share=(0.0 if mode == "lp" else buyback_share))
    router = Router(hook, mode=("lp" if mode == "lp" else "pot")) if mode != "baseline" else None
    w = World(curve, pool, hook, router)
    w.pool_bias = pool_bias; w.venue = venue
    if router is None: w.creator_income += curve.creator_pending; curve.creator_pending = 0.0
    return w

def flow(rng: random.Random, n: int, drift: float):
    """Random order flow in E: lognormal sizes, buy probability drifting."""
    for i in range(n):
        phase = i / n
        p_buy = 0.5 + drift * math.sin(2 * math.pi * phase)      # accumulation then distribution
        size_e = rng.lognormvariate(math.log(0.02), 0.9)          # ~0.02 E typical, fat tail
        yield ("buy", size_e) if rng.random() < p_buy else ("sell", size_e)

def run(mode: str, seed: int, n=3000, drift=0.25, die_at: int | None = None, **kw) -> World:
    """die_at: trade index after which the token sees no flow at all (dead token)."""
    rng = random.Random(seed); random.seed(seed)
    w = build(mode, **kw)
    for i, (action, size_e) in enumerate(flow(rng, n, drift)):
        if die_at is not None and i >= die_at:
            w.log.append(dict(w.log[-1])); w.t += 1; continue
        if action == "buy": w.step("buy", size_e)
        else:
            tk = size_e / w.pool.price                            # sell the E-equivalent in tokens
            tk = min(tk, w.curve.supply * 0.02)
            w.step("sell", tk)
    return w

def summary(w: World) -> dict:
    lg = w.log
    dev = [abs(r["pool_price"] / max(r["curve_price"], 1e-12) - 1) for r in lg if r["curve_price"] > 0]
    dev = dev or [0.0]
    return dict(
        final_L=w.pool.L, L_growth=w.pool.L / lg[0]["L"] - 1,
        pot=w.hook.pot, donated=(w.router.donated if w.router else 0.0),
        dao=(w.router.dao_income if w.router else 0.0), keeper=(w.router.keeper_income if w.router else 0.0),
        creator=w.creator_income + w.hook.fee_recipient_e, protocol=w.curve.protocol_income,
        pumped=w.hook.pumped_e, shielded=w.hook.shielded_e, carry_t=w.hook.carry_t, burned_t=w.hook.burned_t,
        arb_profit=w.arb_profit, mean_dev=sum(dev) / len(dev), max_dev=max(dev),
        supply=w.curve.supply, reserve=w.curve.reserve,
        sell_real=sum(w.sell_real) / max(1, len(w.sell_real)), buy_real=sum(w.buy_real) / max(1, len(w.buy_real)),
        pool_share=w.pool_share / max(1, len(w.log)), locked_frac=(w.hook.carry_t + w.hook.burned_t) / max(1e-9, w.curve.supply),
        recycled=w.hook.recycled_e, stranded_reserve=(w.hook.carry_t + w.hook.burned_t) * w.curve.price() * (1 - w.curve.burn_royalty),
        end_pool_over_curve=lg[-1]["pool_price"] / max(lg[-1]["curve_price"], 1e-12),
        lp_added_e=2 * (w.pool.L - lg[0]["L"]) * w.pool.sqrt_p,
        **recovery(w),
    )

def recovery(w: World) -> dict:
    """What a DAO reclaim of the WHOLE position would return today: ETH side + token side burned on the curve."""
    e_side = w.pool.L * w.pool.sqrt_p
    t_side = w.pool.L / w.pool.sqrt_p
    burn_e = w.curve.burn_refund(min(t_side, w.curve.supply))[0] if w.curve.supply > 0 else 0.0
    invested = (w.router.donated if w.router else 0.0)
    seed_e = 0.4 + 4_000 * w.curve.steps[1][1]                     # the launch seed at the initial price
    # HODL benchmark: the same ETH kept as ETH + the same tokens simply held, valued at today's curve burn price
    hodl_e = seed_e + invested
    return dict(recover_e=e_side + burn_e, e_side=e_side, burn_e=burn_e, invested=invested + seed_e,
                recover_ratio=(e_side + burn_e) / max(1e-12, hodl_e), price_ratio=w.curve.price() / w.curve.steps[1][1])

def table(rows: dict[str, list[dict]], title: str, keys=None):
    modes = list(rows)
    keys = keys or list(rows[modes[0]][0].keys())
    print(f"\n{title}")
    print(f"{'metric':>20} " + " ".join(f"{m:>14}" for m in modes))
    for k in keys:
        print(f"{k:>20} " + " ".join(f"{sum(r[k] for r in rows[m]) / len(rows[m]):>14.5g}" for m in modes))

if __name__ == "__main__":
    SEEDS = range(12)
    KEYS = ["creator", "dao", "donated", "shielded", "pumped", "recycled", "pot", "L_growth", "lp_added_e", "locked_frac", "stranded_reserve",
            "sell_real", "buy_real", "mean_dev", "end_pool_over_curve", "arb_profit", "pool_share", "supply"]
    MODES = ["baseline", "compound", "recycle", "lp"]
    # 1. the destinations for royalties, up-then-down flow
    rows = {m: [summary(run(m, s)) for s in SEEDS] for m in MODES}
    table(rows, "A. Royalty destination (12 seeds × 3000 trades, accumulation → distribution)", KEYS)
    # 2. distribution-heavy flow (net selling): does the shield matter?
    rows = {m: [summary(run(m, s, drift=-0.35)) for s in SEEDS] for m in MODES}
    table(rows, "B. Net-selling regime (drift −0.35)", KEYS)
    # 3. royalty rate sensitivity (compound mode)
    rows = {f"roy={r:.0%}": [summary(run("compound", s, royalty=r)) for s in SEEDS] for r in (0.01, 0.03, 0.05, 0.10)}
    table(rows, "C. Curve royalty rate (compound mode)", ["donated", "shielded", "L_growth", "locked_frac", "sell_real", "mean_dev", "arb_profit"])
    # 5. dead token: flow stops at trade 1500; what can the DAO recover vs. everything that went in (seed + royalties)?
    rows = {"die@600 (early)": [summary(run("lp", s, n=3000, die_at=600)) for s in SEEDS],
            "die@1500 (peak)": [summary(run("lp", s, n=3000, die_at=1500)) for s in SEEDS],
            "die@2500 (post-dump)": [summary(run("lp", s, n=3000, die_at=2500)) for s in SEEDS],
            "alive @3000": [summary(run("lp", s, n=3000)) for s in SEEDS]}
    table(rows, "E. Dead token (lp mode, 3% royalty): what a DAO reclaim returns vs. what went in", ["invested", "e_side", "burn_e", "recover_e", "recover_ratio", "price_ratio", "L_growth"])
    # 4. program split: can more compound share pair the carry faster?
    rows = {f"comp={c:.0%}": [summary(run("compound", s, compound_share=c, buyback_share=1 - c)) for s in SEEDS] for c in (0.2, 0.5, 0.8, 1.0)}
    table(rows, "D. LP-fee split compound vs buyback (compound mode)", ["donated", "L_growth", "locked_frac", "pot", "sell_real"])
