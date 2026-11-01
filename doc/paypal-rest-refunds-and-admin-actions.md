# PayPal REST: refunds and admin payment actions

- **Status:** planning / investigation
- **Scope:** items 6 and 9 from the PayPal REST backend review
- **Related issue:** [openfoodnetwork#5857](https://github.com/openfoodfoundation/openfoodnetwork/issues/5857)
- **Architecture:** [`doc/paypal-integration.md`](paypal-integration.md)
- **Last updated:** 2026-10-26

This document covers two remaining PayPal REST concerns:

1. **Refund UI and the shared refund view** (item 6)
2. **Admin `credit`, `void` and capture actions** (item 9)

Work on the itemised PayPal REST order payload (item 7) is tracked separately.

---

## Part 6: Refund UI and the shared refund view

### Current state

The admin refund flow uses:

```text
app/controllers/spree/admin/payments_controller.rb#paypal_refund
app/views/spree/admin/payments/paypal_refund.html.haml
config/routes/spree.rb
```

Routes:

```ruby
resources :payments, only: [:index, :show, :new, :create] do
  member do
    get 'paypal_refund'
    post 'paypal_refund'
  end
end
```

The view is shared by legacy PayPal and PayPal REST. It renders only generic payment data:

```ruby
@payment
@payment.display_amount
@payment.amount
payment_method_name(@payment)
paypal_refund_admin_order_payment_path(@order, @payment)
```

It does **not** read legacy-specific source fields such as `token` or `transaction_id`.

### Findings

#### 6.1 The shared view itself is reusable

The refund form is the same for both integrations:

- display the original payment amount
- accept `refund_amount`
- POST to the refund action
- show a success or failure flash

A dedicated REST view would duplicate nearly the entire template without adding value today.

**Recommendation:** keep the shared view for now.

#### 6.2 The GET action still assumes the legacy source state

`PaymentsController#paypal_refund` contains:

```ruby
if @payment.source.state == 'refunded'
```

`Spree::PaypalRestCheckout` has:

```text
status
refund_id
refunded_at
```

but no `state`.

Opening the refund page for a REST payment currently raises `NoMethodError`.

**Recommended fix:** introduce a shared source predicate.

```ruby
# app/models/spree/paypal_rest_checkout.rb
def refunded?
  refunded_at.present?
end
```

```ruby
# app/models/spree/paypal_express_checkout.rb
def refunded?
  state == "refunded"
end
```

Then update the controller:

```ruby
if @payment.source.refunded?
```

This removes the dependency on a legacy-specific column.

#### 6.3 There is no link to the refund page

A repository-wide search finds no link to:

```ruby
paypal_refund_admin_order_payment_path(@order, @payment)
```

The only references are the action, route and the refund view itself.

The payment list renders `payment.actions`, which currently exposes the gateway’s default actions instead of this custom refund page.

**Recommendation:** add a visible refund link for completed PayPal REST payments, for example in:

```text
app/views/spree/admin/payments/source_views/_paypal_rest.html.haml
```

Conceptual example:

```haml
- unless payment.source.refunded?
  = link_to Spree.t(:refund, scope: :paypal),
            paypal_refund_admin_order_payment_path(@order, payment)
```

The exact condition should also check that the payment is completed and refundable.

#### 6.4 The POST action already works with `PaypalRest::Result`

Successful refunds work through:

```ruby
response = @payment.payment_method.refund(@payment, params[:refund_amount])
if response.success?
  ...
end
```

The failure message helper was recently fixed so both legacy SOAP errors and `PaypalRest::Result#error_message` are supported.

#### 6.5 Multiple and partial refunds need a decision

The current PayPal REST refund code stores a single:

```text
refund_id
refunded_at
status
```

on the source.

Repeated partial refunds will overwrite `refund_id`.

Options:

1. Accept the current limitation and store only the latest refund.
2. Add a separate refund record/table.
3. Store a JSON array of refund IDs on the source.

This is not required for the first working refund flow, but it should be decided before relying on repeated partial refunds.

### Options

#### Option A: keep the shared view and improve the contract

**Recommended.**

Changes:

- add `refunded?` to both PayPal source models
- update the GET check
- add a refund link from the REST source view or payment list
- keep using `Gateway::PayPalRest#refund`
- keep handling `PaypalRest::Result`

Pros:

- minimal duplication
- one refund form to maintain
- consistent admin UX

Cons:

- REST-specific refund details remain limited to the shared fields
- partial refund history is not represented separately

#### Option B: add a dedicated REST refund view

Would require:

- a new view, e.g. `paypal_rest_refund.html.haml`
- a new action or a branch in `paypal_refund`
- a new route
- duplicated form markup
- separate tests

Pros:

- can show capture ID, REST refund status and refund history
- can evolve independently of legacy PayPal

Cons:

- duplicates the same form
- does not solve discoverability by itself
- more code and tests for little immediate benefit

**Recommendation:** defer this until REST refunds need information the shared form cannot show.

### Implementation checklist for item 6

- [ ] Add `refunded?` to `Spree::PaypalRestCheckout`
- [ ] Add `refunded?` to `Spree::PaypalExpressCheckout`
- [ ] Replace `@payment.source.state == 'refunded'` with `@payment.source.refunded?`
- [ ] Add a refund link for completed PayPal REST payments
- [ ] Confirm the link is hidden after a refund
- [ ] Add controller specs for:
  - [ ] GET refund page for a REST payment
  - [ ] GET refund page for an already-refunded REST payment
  - [ ] successful POST refund
  - [ ] failed POST refund
- [ ] Decide how to handle multiple partial refunds

---

## Part 9: Admin `credit`, `void` and capture actions

### Current state

`Spree::Gateway` exposes:

```ruby
def actions
  %w{capture_and_complete_order void credit resend_authorization_email}
end
```

`Spree::Payment#actions` filters these through:

```ruby
payment_method.actions.select do |action|
  payment_method.__send__("can_#{action}?", self)
end
```

The admin payment list renders one icon per action.

`Spree::Gateway::PayPalRest` does not override `actions` and does not implement `capture`, `void` or `credit`.

### What happens when an admin clicks them

#### `capture_and_complete_order`

```text
payment.capture_and_complete_order!
  → payment.capture!
    → payment_method.capture(...)
```

`PayPalRest` does not implement `capture`, so this falls through to `Spree::Gateway` delegation and fails because there is no ActiveMerchant-style `provider_class`.

#### `void`

```text
payment.void_transaction!
  → payment_method.void(response_code, gateway_options)
```

Not implemented. Same missing-provider failure.

#### `credit`

```text
payment.credit!
  → payment_method.credit(money_in_cents, response_code, gateway_options)
```

Not implemented. Same missing-provider failure.

For completed payments where the order is `credit_owed`, `can_credit?` can return true, so the credit icon may be visible and then fail.

### Findings

#### 9.1 `capture_and_complete_order` is not applicable

The PayPal REST flow uses:

```ruby
intent: CAPTURE
```

The payment is captured during `purchase`. There is no separate authorization to capture later.

**Recommendation:** do not expose `capture_and_complete_order` for this gateway.

#### 9.2 `void` is not a good fit for immediate capture

PayPal’s void endpoint is for authorizations:

```text
POST /v2/payments/authorizations/{authorization_id}/void
```

PayPal REST payments here use immediate capture, so there is no authorization ID.

A captured payment should be refunded, not voided.

Spree’s `void` path also does not create a refund record, so using it to refund a captured payment would leave the payment state inconsistent.

**Recommendation:** do not implement `void` for the current integration.

`void` would only make sense if OFN later switches to:

```ruby
intent: AUTHORIZE
```

and stores PayPal authorization IDs.

#### 9.3 `credit` is feasible

`credit` can be implemented as a PayPal refund. Spree handles the negative payment.

`Spree::Payment#credit!`:

```text
calculates refund amount
  → payment_method.credit(money_in_cents, response_code, gateway_options)
    → creates negative payment if success
```

For PayPal REST, `payment.response_code` should already contain the PayPal capture ID, because `purchase` returns it as the ActiveMerchant authorization.

A possible implementation:

```ruby
def credit(money, capture_id, gateway_options)
  result = client.refund_capture(
    capture_id,
    {
      amount: {
        value: format("%.2f", money / 100.0),
        currency_code: gateway_options[:currency]
      }
    }
  )

  if result.success?
    gateway_options[:payment]&.source&.update!(
      refund_id: result.refund_id,
      refunded_at: Time.zone.now,
      status: "refunded"
    )

    ActiveMerchant::Billing::Response.new(
      true,
      "PayPal refund #{result.status}",
      {},
      authorization: result.refund_id
    )
  else
    ActiveMerchant::Billing::Response.new(false, result.error_message)
  end
end
```

Important: `credit` must **not** call the existing custom `Gateway#refund` method, because:

- `Spree::Payment#credit!` creates the negative payment;
- `Gateway#refund` also creates a negative payment.

Calling both would create two negative payments.

#### 9.4 `credit` has a different amount model from the refund page

`credit!` uses `credit_allowed` and `calculate_refund_amount`, not the arbitrary amount entered on the custom refund form.

So the two paths serve different purposes:

- `credit` action: standard Spree refund flow, typically full/outstanding amount
- `paypal_refund` page: custom amount entry, including partial refunds

Both can coexist, but they must not share code that creates negative payments.

### Options

#### Option A: disable unsupported actions

```ruby
def actions
  []
end
```

Use the custom `paypal_refund` page for refunds.

Pros:

- no broken admin icons
- no risk of double negative payments
- smallest change

Cons:

- refund page needs a visible link
- no standard Spree credit action

**Recommended short-term option.**

#### Option B: support only `credit`

```ruby
def actions
  %w{credit}
end
```

Implement `credit` as above and keep the custom refund page for partial refunds.

Pros:

- standard Spree refund action works
- no broken void/capture icons

Cons:

- two refund paths to maintain
- need to ensure both update the same source fields
- need tests for amount conversion and duplicate prevention

**Reasonable follow-up option.**

#### Option C: implement `void` and capture support

Requires changing the payment model to use authorization + capture instead of immediate capture.

This is a much larger change and is not recommended for the current PayPal REST migration.

### Implementation checklist for item 9

- [ ] Decide between Option A and Option B
- [ ] Override `actions` on `Spree::Gateway::PayPalRest`
- [ ] If using Option B:
  - [ ] implement `credit(money, capture_id, gateway_options)`
  - [ ] convert cents to the correct amount format
  - [ ] update `refund_id`, `refunded_at`, `status`
  - [ ] return an ActiveMerchant response
  - [ ] do not create a negative payment inside `credit`
  - [ ] add specs for successful and failed credit
- [ ] Add specs confirming unsupported actions are not displayed
- [ ] Document that `void` is not supported for immediate-capture payments
- [ ] Revisit `void` only if switching to `intent: AUTHORIZE`

---

## Suggested order of work

1. Finish item 7 (itemised order payload) and verify sandbox create/capture.
2. Add `refunded?` and fix the refund GET check (item 6).
3. Add a visible refund link for completed PayPal REST payments.
4. Disable unsupported gateway actions (item 9, Option A).
5. Decide whether to add `credit` (Option B).
6. Add specs for refunds and admin actions.
7. Revisit multiple partial refunds and the dedicated refund view only if needed.
