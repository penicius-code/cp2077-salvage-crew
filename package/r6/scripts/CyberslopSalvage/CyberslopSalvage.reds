// Cyberslop Salvage 1.1.0 - cargo ledger, wear and field state of the salvage units.
// Units: 1 = android 1 (trunk of any own car), 2 = cargo drone, 3..6 = androids 2..5 (the van).
// 1.1.0: wear per unit (game clock + bodies searched), service paid in crafting components from
// V's bag (missing ones bought at market price), field state kept in the save (a unit that was
// out is still out after a load), FindCar for the trunk / van rule.
// No hooks, no wraps: plain methods, called from CET through
//   Game.GetScriptableSystemsContainer():Get("CyberslopSalvage.CyberslopSalvageSystem")
// Each looted item is appraised ON THE BODY while its item data still exists (weight, vendor sell
// price, tier, real dismantle yield incl. any wrap of CraftingSystem.GetDisassemblyResultItems),
// then removed from the body and kept as a row. Rows are persistent, so they live in the save.
// Taking a row gives V a fresh item of the same record and tier (attachments and random rolls of
// the original are not kept).
// Categories: 0 Weapons, 1 Clothing, 2 Cyberware, 3 Mods, 4 Quickhacks, 5 Consumables,
//             6 Ammo / grenades, 7 Components, 8 Junk / valuables, 9 Iconic / other (kept).
// Revert: delete this folder.
module CyberslopSalvage

public class CyberslopSalvageSystem extends ScriptableSystem {

  // cargo rows, parallel arrays
  private persistent let m_id: array<Int32>;
  private persistent let m_unit: array<Int32>;
  private persistent let m_rec: array<TweakDBID>;
  private persistent let m_qty: array<Int32>;
  private persistent let m_tier: array<Int32>;      // Quality * 2 + IsItemPlus, 0..10
  private persistent let m_cat: array<Int32>;
  private persistent let m_kg: array<Float>;        // one item
  private persistent let m_sell: array<Int32>;      // one item, vendor sell price
  private persistent let m_stack: array<Bool>;
  // dismantle yield of the rows: (row id, component record, amount for the whole row)
  private persistent let m_yId: array<Int32>;
  private persistent let m_yRec: array<TweakDBID>;
  private persistent let m_yQty: array<Int32>;
  private persistent let m_nextId: Int32 = 1;
  // runs in progress
  private persistent let m_jobUnit: array<Int32>;
  private persistent let m_jobMode: array<Int32>;   // 1 recycle, 2 sell
  private persistent let m_jobStart: array<Float>;
  private persistent let m_jobDue: array<Float>;
  private persistent let m_jobMinutes: array<Float>;
  private persistent let m_jobCredits: array<Int32>;
  // what a run brings back besides credits: (unit, record, amount, tier or -1)
  private persistent let m_payUnit: array<Int32>;
  private persistent let m_payRec: array<TweakDBID>;
  private persistent let m_payQty: array<Int32>;
  private persistent let m_payTier: array<Int32>;
  // 1.1.0, per unit (index = unit id, 0 unused; sized by Ensure, so older saves just start at 0)
  private persistent let m_wear: array<Float>;      // 0..100 %
  private persistent let m_served: array<Float>;    // wear serviced so far, modulo 10 (kit bookkeeping)
  private persistent let m_field: array<Int32>;     // 0 home, 1 active, 2 standby
  private persistent let m_fieldAt: array<Float>;   // game clock of the last wear accrual

  private let m_version: Int32 = 1;
  private let m_lastCash: Int32 = 0;
  private let m_lastLeft: Int32 = 0;
  private let m_load: Float = 0.0;
  private let m_serviceText: String;
  private let m_carHow: String;
  // index cache for the per-row getters, rebuilt when the unit or the version changes
  private let m_viewUnit: Int32 = 0;
  private let m_viewVersion: Int32 = 0;
  private let m_view: array<Int32>;

  // ---------- helpers ----------

  private final func Now() -> Float {
    return GameInstance.GetTimeSystem(this.GetGameInstance()).GetGameTimeStamp();
  }

  private final func Player() -> ref<GameObject> {
    return GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
  }

  private final func ValidUnit(unit: Int32) -> Bool {
    return unit >= 1 && unit <= 6;
  }

  private final func Ensure() -> Void {
    while ArraySize(this.m_wear) <= 6 { ArrayPush(this.m_wear, 0.0); };
    while ArraySize(this.m_served) <= 6 { ArrayPush(this.m_served, 0.0); };
    while ArraySize(this.m_field) <= 6 { ArrayPush(this.m_field, 0); };
    while ArraySize(this.m_fieldAt) <= 6 { ArrayPush(this.m_fieldAt, 0.0); };
  }

  public final func UnitName(unit: Int32) -> String {
    if unit == 2 { return "Salvage drone"; };
    if unit == 1 { return "Salvage android 1"; };
    return "Salvage android " + IntToString(unit - 1);
  }

  private final func TierName(tier: Int32) -> CName {
    switch tier {
      case 1: return n"CommonPlus";
      case 2: return n"Uncommon";
      case 3: return n"UncommonPlus";
      case 4: return n"Rare";
      case 5: return n"RarePlus";
      case 6: return n"Epic";
      case 7: return n"EpicPlus";
      case 8: return n"Legendary";
      case 9: return n"LegendaryPlus";
      case 10: return n"LegendaryPlusPlus";
    };
    return n"Common";
  }

  private final func CategoryOf(data: wref<gameItemData>, cat: gamedataItemCategory, type: gamedataItemType) -> Int32 {
    if RPGManager.IsItemIconic(data) { return 9; };
    if Equals(type, gamedataItemType.Prt_Program) || data.HasTag(n"SoftwareShard") || data.HasTag(n"QuickhackCraftingPart") { return 4; };
    if Equals(cat, gamedataItemCategory.Weapon) { return 0; };
    if Equals(cat, gamedataItemCategory.Clothing) { return 1; };
    if Equals(cat, gamedataItemCategory.Cyberware) { return 2; };
    if Equals(cat, gamedataItemCategory.Part) || Equals(cat, gamedataItemCategory.WeaponMod) { return 3; };
    if Equals(type, gamedataItemType.Con_Ammo) || Equals(cat, gamedataItemCategory.Gadget) { return 6; };
    if Equals(cat, gamedataItemCategory.Consumable) { return 5; };
    if Equals(type, gamedataItemType.Gen_CraftingMaterial) { return 7; };
    if Equals(type, gamedataItemType.Gen_Junk) || Equals(type, gamedataItemType.Gen_Jewellery) { return 8; };
    return 9;
  }

  private final func IsBodyWeapon(type: gamedataItemType) -> Bool {
    return Equals(type, gamedataItemType.Wea_Fists) || Equals(type, gamedataItemType.Cyb_StrongArms)
      || Equals(type, gamedataItemType.Cyb_MantisBlades) || Equals(type, gamedataItemType.Cyb_NanoWires)
      || Equals(type, gamedataItemType.Cyb_Launcher);
  }

  private final func AddYield(id: Int32, rec: TweakDBID, qty: Int32) -> Void {
    let i: Int32 = 0;
    if qty <= 0 { return; };
    while i < ArraySize(this.m_yId) {
      if this.m_yId[i] == id && this.m_yRec[i] == rec {
        this.m_yQty[i] += qty;
        return;
      };
      i += 1;
    };
    ArrayPush(this.m_yId, id);
    ArrayPush(this.m_yRec, rec);
    ArrayPush(this.m_yQty, qty);
  }

  private final func DropYield(id: Int32) -> Void {
    let i: Int32 = ArraySize(this.m_yId) - 1;
    while i >= 0 {
      if this.m_yId[i] == id {
        ArrayErase(this.m_yId, i);
        ArrayErase(this.m_yRec, i);
        ArrayErase(this.m_yQty, i);
      };
      i -= 1;
    };
  }

  private final func HasYield(id: Int32) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_yId) {
      if this.m_yId[i] == id { return true; };
      i += 1;
    };
    return false;
  }

  private final func DropRow(i: Int32) -> Void {
    this.DropYield(this.m_id[i]);
    ArrayErase(this.m_id, i);
    ArrayErase(this.m_unit, i);
    ArrayErase(this.m_rec, i);
    ArrayErase(this.m_qty, i);
    ArrayErase(this.m_tier, i);
    ArrayErase(this.m_cat, i);
    ArrayErase(this.m_kg, i);
    ArrayErase(this.m_sell, i);
    ArrayErase(this.m_stack, i);
  }

  private final func AddPay(unit: Int32, rec: TweakDBID, qty: Int32, tier: Int32) -> Void {
    let i: Int32 = 0;
    if qty <= 0 { return; };
    if tier < 0 {
      while i < ArraySize(this.m_payUnit) {
        if this.m_payUnit[i] == unit && this.m_payRec[i] == rec && this.m_payTier[i] < 0 {
          this.m_payQty[i] += qty;
          return;
        };
        i += 1;
      };
    };
    ArrayPush(this.m_payUnit, unit);
    ArrayPush(this.m_payRec, rec);
    ArrayPush(this.m_payQty, qty);
    ArrayPush(this.m_payTier, tier);
  }

  // gives V qty items of a record; tier >= 0 forces the tier on a single (non-stack) item
  private final func Hand(rec: TweakDBID, qty: Int32, tier: Int32) -> Bool {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(this.GetGameInstance());
    let player: ref<GameObject> = this.Player();
    let itemID: ItemID;
    let n: Int32 = 0;
    if !IsDefined(player) || qty <= 0 { return false; };
    if tier < 0 {
      return ts.GiveItem(player, ItemID.FromTDBID(rec), qty);
    };
    while n < qty {
      itemID = ItemID.FromTDBID(rec);
      if !ts.GiveItem(player, itemID, 1) { return n > 0; };
      RPGManager.ForceItemTier(player, ts.GetItemData(player, itemID), this.TierName(tier));
      n += 1;
    };
    return true;
  }

  private final func JobIndex(unit: Int32) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_jobUnit) {
      if this.m_jobUnit[i] == unit { return i; };
      i += 1;
    };
    return -1;
  }

  private final func RowIndex(entryId: Int32) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_id) {
      if this.m_id[i] == entryId { return i; };
      i += 1;
    };
    return -1;
  }

  private final func View(unit: Int32, index: Int32) -> Int32 {
    let i: Int32;
    if this.m_viewUnit != unit || this.m_viewVersion != this.m_version {
      ArrayClear(this.m_view);
      i = 0;
      while i < ArraySize(this.m_id) {
        if this.m_unit[i] == unit { ArrayPush(this.m_view, i); };
        i += 1;
      };
      this.m_viewUnit = unit;
      this.m_viewVersion = this.m_version;
    };
    if index < 0 || index >= ArraySize(this.m_view) { return -1; };
    return this.m_view[index];
  }

  // ---------- looting ----------

  // Takes what fits from a downed NPC (or any object with an inventory).
  // Returns the number of items taken, -1 when the unit is full and nothing fitted.
  // Cash goes straight to V (LastCash), shards and keycards too. Quest items stay on the body.
  public final func LootFrom(unit: Int32, source: ref<GameObject>, capacityKg: Float) -> Int32 {
    let player: ref<GameObject> = this.Player();
    let items: array<wref<gameItemData>>;
    let i: Int32 = 0;
    let taken: Int32 = 0;
    this.m_lastCash = 0;
    this.m_lastLeft = 0;
    if !IsDefined(source) || !IsDefined(player) || this.JobIndex(unit) >= 0 { return 0; };
    if this.ValidUnit(unit) {
      this.Ensure();
      this.m_wear[unit] = MinF(100.0, this.m_wear[unit] + 0.5);   // one body searched
    };
    this.m_load = this.CargoKg(unit);
    GameInstance.GetTransactionSystem(this.GetGameInstance()).GetItemList(source, items);
    while i < ArraySize(items) {
      if IsDefined(items[i]) {
        taken += this.LootOne(unit, source, player, items[i], capacityKg);
      };
      i += 1;
    };
    if taken > 0 || this.m_lastCash > 0 { this.m_version += 1; };
    if taken == 0 && this.m_lastLeft > 0 { return -1; };
    return taken;
  }

  private final func LootOne(unit: Int32, source: ref<GameObject>, player: ref<GameObject>, data: wref<gameItemData>, capacityKg: Float) -> Int32 {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(this.GetGameInstance());
    let itemID: ItemID = data.GetID();
    let tdb: TweakDBID = ItemID.GetTDBID(itemID);
    let rec: wref<Item_Record> = TweakDBInterface.GetItemRecord(tdb);
    let qty: Int32 = data.GetQuantity();
    let type: gamedataItemType;
    let cat: gamedataItemCategory;
    let attachments: array<ItemAttachments>;
    let yield: array<IngredientData>;
    let fit: Int32;
    let kg: Float;
    let row: Int32 = -1;
    let rowId: Int32;
    let myCat: Int32;
    let tier: Int32;
    let stack: Bool;
    let j: Int32;
    if !IsDefined(rec) || qty <= 0 || data.HasTag(n"Quest") || data.HasTag(n"HideInUI") { return 0; };
    if !IsDefined(rec.ItemType()) || !IsDefined(rec.ItemCategory()) { return 0; };
    type = rec.ItemType().Type();
    cat = rec.ItemCategory().Type();
    if this.IsBodyWeapon(type) { return 0; };
    if tdb == t"Items.money" {
      if ts.TransferItem(source, player, itemID, qty) { this.m_lastCash += qty; };
      return 0;
    };
    if Equals(type, gamedataItemType.Gen_Readable) || Equals(type, gamedataItemType.Gen_Keycard) {
      ts.TransferItem(source, player, itemID, qty);
      return 0;
    };
    kg = RPGManager.GetItemWeight(data);
    if kg > 0.0 && this.m_load + kg * Cast<Float>(qty) > capacityKg {
      fit = FloorF((capacityKg - this.m_load) / kg);
      if fit <= 0 {
        this.m_lastLeft += qty;
        return 0;
      };
      this.m_lastLeft += qty - fit;
      qty = fit;
    };
    myCat = this.CategoryOf(data, cat, type);
    tier = RoundF(data.GetStatValueByType(gamedataStatType.Quality) * 2.0 + data.GetStatValueByType(gamedataStatType.IsItemPlus));
    if tier < 0 { tier = 0; };
    if tier > 10 { tier = 10; };
    stack = data.HasTag(n"Stackable") || (myCat >= 5 && myCat <= 8);
    // appraise while the item is still on the body (calledFromUI = true: preview only, no perk side effects)
    yield = CraftingSystem.GetInstance(this.GetGameInstance()).GetDisassemblyResultItems(source, itemID, qty, attachments, true);
    if stack {
      j = 0;
      while j < ArraySize(this.m_id) && row < 0 {
        if this.m_unit[j] == unit && this.m_stack[j] && this.m_rec[j] == tdb && this.m_tier[j] == tier { row = j; };
        j += 1;
      };
    };
    if row >= 0 {
      this.m_qty[row] += qty;
      rowId = this.m_id[row];
    } else {
      rowId = this.m_nextId;
      this.m_nextId += 1;
      ArrayPush(this.m_id, rowId);
      ArrayPush(this.m_unit, unit);
      ArrayPush(this.m_rec, tdb);
      ArrayPush(this.m_qty, qty);
      ArrayPush(this.m_tier, tier);
      ArrayPush(this.m_cat, myCat);
      ArrayPush(this.m_kg, kg);
      ArrayPush(this.m_sell, RPGManager.CalculateSellPriceItemData(this.GetGameInstance(), player, data));
      ArrayPush(this.m_stack, stack);
    };
    // components are handed over as they are, the kept category is never processed: no yield rows
    if myCat != 7 && myCat != 9 {
      j = 0;
      while j < ArraySize(yield) {
        if IsDefined(yield[j].id) {
          this.AddYield(rowId, yield[j].id.GetID(), yield[j].quantity);
        };
        j += 1;
      };
    };
    ts.RemoveItem(source, itemID, qty);
    this.m_load += kg * Cast<Float>(qty);
    return qty;
  }

  public final func LastCash() -> Int32 { return this.m_lastCash; }
  // items left on the last body because the unit was full
  public final func LastLeft() -> Int32 { return this.m_lastLeft; }

  // ---------- window ----------

  public final func Version() -> Int32 { return this.m_version; }

  public final func Count(unit: Int32) -> Int32 {
    this.View(unit, 0);
    return ArraySize(this.m_view);
  }

  public final func CargoKg(unit: Int32) -> Float {
    let kg: Float = 0.0;
    let i: Int32 = 0;
    while i < ArraySize(this.m_id) {
      if this.m_unit[i] == unit { kg += this.m_kg[i] * Cast<Float>(this.m_qty[i]); };
      i += 1;
    };
    return kg;
  }

  // vendor sell value of everything a sale would sell, before the fence cut
  public final func EstSell(unit: Int32) -> Int32 {
    let sum: Int32 = 0;
    let i: Int32 = 0;
    while i < ArraySize(this.m_id) {
      if this.m_unit[i] == unit && this.m_cat[i] != 7 && this.m_cat[i] != 9 { sum += this.m_sell[i] * this.m_qty[i]; };
      i += 1;
    };
    return sum;
  }

  // number of components a recycle run would bring
  public final func EstComponents(unit: Int32) -> Int32 {
    let sum: Int32 = 0;
    let i: Int32 = 0;
    let row: Int32;
    while i < ArraySize(this.m_yId) {
      row = this.RowIndex(this.m_yId[i]);
      if row >= 0 && this.m_unit[row] == unit { sum += this.m_yQty[i]; };
      i += 1;
    };
    return sum;
  }

  public final func EntryId(unit: Int32, index: Int32) -> Int32 {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 0 : this.m_id[i];
  }

  public final func Rec(unit: Int32, index: Int32) -> TweakDBID {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? TDBID.None() : this.m_rec[i];
  }

  // localized item name, so CET needs no record lookup per row
  public final func Name(unit: Int32, index: Int32) -> String {
    let i: Int32 = this.View(unit, index);
    let rec: wref<Item_Record>;
    let text: String;
    if i < 0 { return ""; };
    rec = TweakDBInterface.GetItemRecord(this.m_rec[i]);
    if IsDefined(rec) { text = GetLocalizedTextByKey(rec.DisplayName()); };
    if Equals(text, "") { text = TDBID.ToStringDEBUG(this.m_rec[i]); };
    return text;
  }

  public final func Qty(unit: Int32, index: Int32) -> Int32 {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 0 : this.m_qty[i];
  }

  public final func Tier(unit: Int32, index: Int32) -> Int32 {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 0 : this.m_tier[i];
  }

  public final func Cat(unit: Int32, index: Int32) -> Int32 {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 9 : this.m_cat[i];
  }

  // weight of the whole row
  public final func Kg(unit: Int32, index: Int32) -> Float {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 0.0 : this.m_kg[i] * Cast<Float>(this.m_qty[i]);
  }

  // vendor sell value of the whole row
  public final func Sell(unit: Int32, index: Int32) -> Int32 {
    let i: Int32 = this.View(unit, index);
    return i < 0 ? 0 : this.m_sell[i] * this.m_qty[i];
  }

  // ---------- taking ----------

  private final func TakeRow(i: Int32) -> Bool {
    let tier: Int32 = -1;
    if !this.m_stack[i] && (this.m_cat[i] <= 2 || this.m_cat[i] == 9) { tier = this.m_tier[i]; };
    if !this.Hand(this.m_rec[i], this.m_qty[i], tier) { return false; };
    this.DropRow(i);
    return true;
  }

  // one click: the whole row goes to V
  public final func Take(entryId: Int32) -> Bool {
    let i: Int32 = this.RowIndex(entryId);
    if i < 0 || this.JobIndex(this.m_unit[i]) >= 0 { return false; };
    if !this.TakeRow(i) { return false; };
    this.m_version += 1;
    return true;
  }

  // cat < 0 = everything
  public final func TakeCategory(unit: Int32, cat: Int32) -> Int32 {
    let n: Int32 = 0;
    let i: Int32 = ArraySize(this.m_id) - 1;
    if this.JobIndex(unit) >= 0 { return 0; };
    while i >= 0 {
      if this.m_unit[i] == unit && (cat < 0 || this.m_cat[i] == cat) {
        if this.TakeRow(i) { n += 1; };
      };
      i -= 1;
    };
    if n > 0 { this.m_version += 1; };
    return n;
  }

  // ---------- runs ----------

  // mode 1 = recycle (what can't be dismantled is sold), 2 = sell. fenceRate = share of the vendor
  // sell price that is paid (0.80). Components and the kept category come back as they are.
  // The caller sends the unit away; Update() pays out when the game clock reaches the due time.
  public final func Dispatch(unit: Int32, mode: Int32, minutes: Float, fenceRate: Float) -> Bool {
    let credits: Float = 0.0;
    let i: Int32;
    let j: Int32;
    let id: Int32;
    let now: Float;
    let any: Bool = false;
    if this.JobIndex(unit) >= 0 || mode < 1 || mode > 2 { return false; };
    i = ArraySize(this.m_id) - 1;
    while i >= 0 {
      if this.m_unit[i] == unit {
        any = true;
        id = this.m_id[i];
        if this.m_cat[i] == 7 || this.m_cat[i] == 9 {
          this.AddPay(unit, this.m_rec[i], this.m_qty[i], this.m_stack[i] ? -1 : this.m_tier[i]);
        } else {
          if mode == 1 && this.HasYield(id) {
            j = 0;
            while j < ArraySize(this.m_yId) {
              if this.m_yId[j] == id { this.AddPay(unit, this.m_yRec[j], this.m_yQty[j], -1); };
              j += 1;
            };
          } else {
            if this.m_sell[i] > 0 {
              credits += Cast<Float>(this.m_sell[i] * this.m_qty[i]) * fenceRate;
            } else {
              // nothing to dismantle and no buyer (ammo): comes back
              this.AddPay(unit, this.m_rec[i], this.m_qty[i], -1);
            };
          };
        };
        this.DropRow(i);
      };
      i -= 1;
    };
    if !any { return false; };
    now = this.Now();
    ArrayPush(this.m_jobUnit, unit);
    ArrayPush(this.m_jobMode, mode);
    ArrayPush(this.m_jobStart, now);
    ArrayPush(this.m_jobDue, now + minutes * 60.0);
    ArrayPush(this.m_jobMinutes, minutes);
    ArrayPush(this.m_jobCredits, FloorF(credits));
    // on a trip = not in the field: no wear for it, and a load does not find it "out"
    if this.ValidUnit(unit) {
      this.Accrue();
      this.m_field[unit] = 0;
    };
    this.m_version += 1;
    return true;
  }

  // game minutes until the unit is back, 0 = not away
  public final func AwayMinutesLeft(unit: Int32) -> Float {
    let j: Int32 = this.JobIndex(unit);
    let left: Float;
    if j < 0 { return 0.0; };
    left = (this.m_jobDue[j] - this.Now()) / 60.0;
    return left > 0.01 ? left : 0.01;
  }

  public final func IsAway(unit: Int32) -> Bool { return this.JobIndex(unit) >= 0; }

  // Call about once a second. Pays out finished runs and returns the notice text, "" when nothing ended.
  public final func Update() -> String {
    let ts: ref<TransactionSystem>;
    let player: ref<GameObject>;
    let now: Float;
    let text: String = "";
    let unit: Int32;
    let comps: Int32;
    let items: Int32;
    let i: Int32;
    let j: Int32 = ArraySize(this.m_jobUnit) - 1;
    this.Accrue();
    if j < 0 { return ""; };
    now = this.Now();
    player = this.Player();
    if !IsDefined(player) { return ""; };
    ts = GameInstance.GetTransactionSystem(this.GetGameInstance());
    while j >= 0 {
      // game clock set back (quest time jump): restart the wait instead of waiting for days
      if now < this.m_jobStart[j] {
        this.m_jobStart[j] = now;
        this.m_jobDue[j] = now + this.m_jobMinutes[j] * 60.0;
      };
      if now >= this.m_jobDue[j] {
        unit = this.m_jobUnit[j];
        comps = 0;
        items = 0;
        if this.m_jobCredits[j] > 0 {
          ts.GiveItem(player, ItemID.FromTDBID(t"Items.money"), this.m_jobCredits[j]);
        };
        i = ArraySize(this.m_payUnit) - 1;
        while i >= 0 {
          if this.m_payUnit[i] == unit {
            this.Hand(this.m_payRec[i], this.m_payQty[i], this.m_payTier[i]);
            if Equals(RPGManager.GetItemType(ItemID.FromTDBID(this.m_payRec[i])), gamedataItemType.Gen_CraftingMaterial) {
              comps += this.m_payQty[i];
            } else {
              items += this.m_payQty[i];
            };
            ArrayErase(this.m_payUnit, i);
            ArrayErase(this.m_payRec, i);
            ArrayErase(this.m_payQty, i);
            ArrayErase(this.m_payTier, i);
          };
          i -= 1;
        };
        if NotEquals(text, "") { text += " | "; };
        text += this.UnitName(unit) + " back: ";
        text += (this.m_jobMode[j] == 2 ? "sold" : "recycled");
        if this.m_jobCredits[j] > 0 { text += ", " + IntToString(this.m_jobCredits[j]) + " eddies"; };
        if comps > 0 { text += ", " + IntToString(comps) + " components"; };
        if items > 0 { text += ", " + IntToString(items) + " items returned"; };
        ArrayErase(this.m_jobUnit, j);
        ArrayErase(this.m_jobMode, j);
        ArrayErase(this.m_jobStart, j);
        ArrayErase(this.m_jobDue, j);
        ArrayErase(this.m_jobMinutes, j);
        ArrayErase(this.m_jobCredits, j);
        this.m_version += 1;
      };
      j -= 1;
    };
    return text;
  }

  // ---------- field state and wear (1.1.0) ----------

  // Books the game time each unit spent in the field since the last call:
  // 2 % per game hour active, 0.5 % per game hour on standby.
  private final func Accrue() -> Void {
    let now: Float = this.Now();
    let unit: Int32 = 1;
    let hours: Float;
    this.Ensure();
    while unit <= 6 {
      if this.m_field[unit] != 0 {
        hours = (now - this.m_fieldAt[unit]) / 3600.0;
        // clock set back, or a quest time jump of more than 30 h: no wear for it
        if hours > 0.0 && hours <= 30.0 {
          this.m_wear[unit] = MinF(100.0, this.m_wear[unit] + hours * (this.m_field[unit] == 2 ? 0.5 : 2.0));
        };
        this.m_fieldAt[unit] = now;
      };
      unit += 1;
    };
  }

  // state: 0 home (stowed), 1 active, 2 standby
  public final func SetField(unit: Int32, state: Int32) -> Void {
    if !this.ValidUnit(unit) || state < 0 || state > 2 { return; };
    this.Accrue();
    this.m_field[unit] = state;
    this.m_fieldAt[unit] = this.Now();
  }

  public final func Field(unit: Int32) -> Int32 {
    if !this.ValidUnit(unit) { return 0; };
    this.Ensure();
    return this.m_field[unit];
  }

  // 0..100 %, condition = 100 - wear
  public final func Wear(unit: Int32) -> Float {
    if !this.ValidUnit(unit) { return 0.0; };
    this.Ensure();
    return this.m_wear[unit];
  }

  // ---------- service (1.1.0) ----------
  // Kit per 10 % wear: 6 Common + 3 Uncommon + 1 Rare crafting components, out of V's bag. A missing
  // component is bought at its market price. m_served keeps the wear serviced so far (modulo 10),
  // so many small services cost exactly what one big one does.

  private final func CompID(q: Int32) -> TweakDBID {
    switch q {
      case 0: return t"Items.CommonMaterial1";
      case 1: return t"Items.UncommonMaterial1";
    };
    return t"Items.RareMaterial1";
  }

  // market price of one component (Cyberslop Materials Economy, the numbers Chrome Upkeep uses)
  private final func CompPrice(q: Int32) -> Int32 {
    switch q {
      case 0: return 25;
      case 1: return 50;
    };
    return 120;
  }

  private final func CompName(q: Int32) -> String {
    switch q {
      case 0: return "Common";
      case 1: return "Uncommon";
    };
    return "Rare";
  }

  private final func KitCount(unit: Int32, q: Int32) -> Int32 {
    let rate: Float = 0.1;
    let s: Float = this.m_served[unit];
    if q == 0 { rate = 0.6; };
    if q == 1 { rate = 0.3; };
    return FloorF((s + this.m_wear[unit]) * rate + 0.0001) - FloorF(s * rate + 0.0001);
  }

  // what comes out of V's bag and what must be bought; returns the eddies for the bought ones
  private final func PlanService(unit: Int32, out take: array<Int32>, out buy: array<Int32>) -> Int32 {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(this.GetGameInstance());
    let player: ref<GameObject> = this.Player();
    let q: Int32 = 0;
    let need: Int32;
    let have: Int32;
    let cost: Int32 = 0;
    ArrayClear(take);
    ArrayClear(buy);
    while q < 3 {
      need = this.KitCount(unit, q);
      have = 0;
      if IsDefined(player) {
        have = ts.GetItemQuantityWithDuplicates(player, ItemID.CreateQuery(this.CompID(q)));
      };
      if have > need { have = need; };
      if have < 0 { have = 0; };
      ArrayPush(take, have);
      ArrayPush(buy, need - have);
      cost += (need - have) * this.CompPrice(q);
      q += 1;
    };
    return cost;
  }

  private final func KitText(counts: array<Int32>) -> String {
    let text: String = "";
    let q: Int32 = 0;
    while q < ArraySize(counts) {
      if counts[q] > 0 {
        if NotEquals(text, "") { text += ", "; };
        text += IntToString(counts[q]) + " " + this.CompName(q);
      };
      q += 1;
    };
    return text;
  }

  // what a service would use right now (window line), "" while nothing is due
  public final func ServiceQuote(unit: Int32) -> String {
    let take: array<Int32>;
    let buy: array<Int32>;
    let cost: Int32;
    let used: String;
    let bought: String;
    let text: String = "Service: ";
    if !this.ValidUnit(unit) { return ""; };
    this.Ensure();
    if this.m_wear[unit] < 1.0 { return ""; };
    cost = this.PlanService(unit, take, buy);
    used = this.KitText(take);
    bought = this.KitText(buy);
    if Equals(used, "") && Equals(bought, "") { return "Service: no parts due yet"; };
    if NotEquals(used, "") { text += used + " from your bag"; };
    if NotEquals(bought, "") {
      if NotEquals(used, "") { text += ", "; };
      text += "buy " + bought + " for " + IntToString(cost) + " eddies";
    };
    return text;
  }

  // Services a stowed unit: 1 = done, 0 = nothing due (wear under 1 %), -1 = V can't pay for the
  // missing components (nothing is taken), -2 = the unit is out or away. ServiceText() is the notice.
  public final func Service(unit: Int32) -> Int32 {
    let ts: ref<TransactionSystem> = GameInstance.GetTransactionSystem(this.GetGameInstance());
    let player: ref<GameObject> = this.Player();
    let take: array<Int32>;
    let buy: array<Int32>;
    let cost: Int32;
    let wear: Float;
    let used: String;
    let bought: String;
    let text: String;
    let q: Int32 = 0;
    this.m_serviceText = "";
    if !this.ValidUnit(unit) || !IsDefined(player) { return 0; };
    this.Accrue();
    if this.m_field[unit] != 0 || this.JobIndex(unit) >= 0 { return -2; };
    wear = this.m_wear[unit];
    if wear < 1.0 { return 0; };
    cost = this.PlanService(unit, take, buy);
    if cost > ts.GetItemQuantity(player, MarketSystem.Money()) {
      this.m_serviceText = this.UnitName(unit) + " not serviced: " + this.KitText(buy) + " components missing, "
        + IntToString(cost) + " eddies needed to buy them.";
      return -1;
    };
    while q < 3 {
      if take[q] > 0 { ts.RemoveItemByTDBID(player, this.CompID(q), take[q], true); };
      q += 1;
    };
    if cost > 0 { ts.RemoveItem(player, MarketSystem.Money(), cost); };
    this.m_served[unit] += wear;
    while this.m_served[unit] >= 10.0 { this.m_served[unit] -= 10.0; };
    this.m_wear[unit] = 0.0;
    used = this.KitText(take);
    bought = this.KitText(buy);
    text = this.UnitName(unit) + " serviced (" + IntToString(RoundF(wear)) + " % wear)";
    if NotEquals(used, "") { text += ": " + used + " components used"; };
    if NotEquals(bought, "") {
      text += (Equals(used, "") ? ": " : ", ") + bought + " bought for " + IntToString(cost) + " eddies";
    };
    this.m_serviceText = text + ".";
    this.m_version += 1;
    return 1;
  }

  public final func ServiceText() -> String { return this.m_serviceText; }

  // ---------- trunk / van (1.1.0) ----------

  private final func CarOk(veh: wref<VehicleObject>, vanOnly: Bool, from: Vector4, maxDist: Float) -> Bool {
    let rec: wref<Vehicle_Record>;
    if !IsDefined(veh) || !veh.IsPlayerVehicle() || veh.IsDestroyed() { return false; };
    if !IsDefined(veh as CarObject) { return false; };   // bikes, tanks and AVs have no trunk
    if Vector4.Distance(from, veh.GetWorldPosition()) > maxDist { return false; };
    if vanOnly {
      rec = veh.GetRecord();
      if !IsDefined(rec) || !IsDefined(rec.Model()) { return false; };
      if NotEquals(rec.Model().Type(), gamedataVehicleModel.Columbus) { return false; };
    };
    return true;
  }

  // One of V's own cars within maxDist (vanOnly: a Villefort Columbus), nearest first; null = none.
  // Looks at the car V sits in, then the cars around V, then the car V called last. CarHow() says
  // which of the three found it.
  public final func FindCar(vanOnly: Bool, maxDist: Float) -> ref<VehicleObject> {
    let gi: GameInstance = this.GetGameInstance();
    let player: ref<GameObject> = this.Player();
    let veh: wref<VehicleObject>;
    let best: wref<VehicleObject>;
    let bestD: Float;
    let d: Float;
    let from: Vector4;
    let query: TargetSearchQuery;
    let parts: array<TS_TargetPartInfo>;
    let comp: wref<TargetingComponent>;
    let id: EntityID;
    let i: Int32 = 0;
    this.m_carHow = "none";
    if !IsDefined(player) { return null; };
    from = player.GetWorldPosition();
    if VehicleComponent.GetVehicle(gi, player, veh) && this.CarOk(veh, vanOnly, from, maxDist + 10.0) {
      this.m_carHow = "mounted";
      return veh;
    };
    query = TSQ_ALL();
    query.testedSet = TargetingSet.Complete;
    query.maxDistance = maxDist + 6.0;
    query.filterObjectByDistance = true;
    query.includeSecondaryTargets = false;
    query.ignoreInstigator = true;
    GameInstance.GetTargetingSystem(gi).GetTargetParts(player, query, parts);
    bestD = maxDist + 1.0;
    while i < ArraySize(parts) {
      comp = TS_TargetPartInfo.GetComponent(parts[i]);
      if IsDefined(comp) {
        veh = comp.GetEntity() as VehicleObject;
        if this.CarOk(veh, vanOnly, from, maxDist) {
          d = Vector4.Distance(from, veh.GetWorldPosition());
          if d < bestD {
            best = veh;
            bestD = d;
          };
        };
      };
      i += 1;
    };
    if IsDefined(best) {
      this.m_carHow = "targeting";
      return best;
    };
    id = GameInstance.GetBlackboardSystem(gi).Get(GetAllBlackboardDefs().VehicleSummonData)
      .GetEntityID(GetAllBlackboardDefs().VehicleSummonData.SummonedVehicleEntityID);
    if EntityID.IsDefined(id) {
      veh = GameInstance.FindEntityByID(gi, id) as VehicleObject;
      if this.CarOk(veh, vanOnly, from, maxDist) {
        this.m_carHow = "summon";
        return veh;
      };
    };
    return null;
  }

  public final func CarHow() -> String { return this.m_carHow; }
}
