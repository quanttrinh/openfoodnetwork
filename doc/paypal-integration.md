# PayPal integration: current implementation and proposed REST architecture

- **Status:** design note / proposal — not implemented
- **Related issue:** [openfoodnetwork#5857](https://github.com/openfoodfoundation/openfoodnetwork/issues/5857)
- **Last updated:** 2026-10-26
- **Context:** OFN currently uses the deprecated `paypal-sdk-merchant` (NVP/SOAP) integration. This document describes the existing implementation and a proposed parallel REST implementation using `paypal-server-sdk` (Orders v2 / Payments v2).

> **Note:** The issue originally proposed `Checkout-Ruby-SDK`. That gem is now deprecated in favour of `paypal-server-sdk`. The target should be updated accordingly.

---

## 1. Summary

The current PayPal integration is a single NVP/SOAP gateway tightly coupled to `paypal-sdk-merchant` response objects. It stores NVP API credentials (login/password/signature), uses `SetExpressCheckout` / `GetExpressCheckoutDetails` / `DoExpressCheckoutPayment`, and refunds through `RefundTransaction`.

The proposed approach is to add a **second, independent PayPal integration** rather than modifying the legacy one in place:

- legacy `Spree::Gateway::PayPalExpress` stays untouched;
- new `Spree::Gateway::PayPalRest` uses `paypal-server-sdk` and the REST Orders v2 / Payments v2 APIs;
- each gateway has its own controller, routes, source model and payload builders;
- both integrations share only stable OFN domain behaviour (order completion, stock checks, payment lookup).

This allows per-enterprise migration, keeps legacy refunds and in-flight checkouts working, and provides a straightforward rollback path.

---

## 2. Current implementation

### 2.1 High-level structure

```text
CheckoutController#redirect_to_payment_gateway
  └── Gateway::PayPalExpress#external_payment_url
        └── GET /paypal?payment_method_id=...

PaymentGateways::PaypalController
  ├── Orders::FindPaymentService
  ├── Paypal::PaymentDetailsService
  │     └── Paypal::ItemsBuilderService
  ├── OrderCompletion / OrderStockCheck
  └── Gateway::PayPalExpress#provider
        └── PayPal::SDK::Merchant::API  (NVP/SOAP)

Spree::Payment#process_payments!
  └── Gateway::PayPalExpress#purchase
        ├── GetExpressCheckoutDetails
        └── DoExpressCheckoutPayment

Admin refund
  └── PaymentsController#paypal_refund
        └── Gateway::PayPalExpress#refund
              └── RefundTransaction
```

### 2.2 File map

```text
Gemfile / Gemfile.lock
└── paypal-sdk-merchant (1.117.4)

config/
├── initializers/paypal.rb              # CAFileHack monkey-patch
└── routes.rb                           # /paypal, /paypal/confirm, /paypal/cancel

app/models/spree/
├── gateway/pay_pal_express.rb          # legacy gateway
└── paypal_express_checkout.rb          # source model

app/controllers/
├── payment_gateways/paypal_controller.rb
└── spree/admin/payments_controller.rb  # #paypal_refund

app/services/
├── paypal/payment_details_service.rb
├── paypal/items_builder_service.rb
└── orders/find_payment_service.rb      # last_pending_paypal_payment

app/views/
├── checkout/payment/_paypal.html.haml
└── spree/admin/payments/
    ├── paypal_refund.html.haml
    ├── source_forms/_paypal.html.haml
    └── source_views/_paypal.html.haml
```

Supporting configuration and admin code:

```text
app/controllers/spree/admin/payment_methods_controller.rb
  └── PAYMENT_METHODS includes Spree::Gateway::PayPalExpress

app/services/permitted_attributes/payment_method.rb
  └── permits preferred_login, preferred_password, preferred_signature, ...

lib/reporting/reports/payments/payment_totals.rb
  └── matches payment methods whose name contains "PayPal"

config/locales/en.yml
  └── PayPal provider labels, refund labels and flash messages
```

Tests:

```text
spec/support/request/paypal_helper.rb        # SOAP XML stubs
spec/controllers/payment_gateways/paypal_controller_spec.rb
spec/requests/checkout/paypal_spec.rb
spec/system/consumer/shopping/checkout_paypal_spec.rb
spec/system/consumer/checkout/payment_spec.rb
spec/system/admin/payment_method_spec.rb
```

### 2.3 Gateway: `Spree::Gateway::PayPalExpress`

```ruby
class PayPalExpress < Gateway
  preference :login, :string
  preference :password, :password
  preference :signature, :string
  preference :server, :string, default: "sandbox"
  preference :solution, :string, default: "Mark"
  preference :landing_page, :string, default: "Billing"
  preference :logourl, :string, default: ""

  def external_gateway? = true
  def method_type = "paypal"

  def external_payment_url(_options)
    payment_gateways_paypal_express_path(payment_method_id: id)
  end

  def provider_class = ::PayPal::SDK::Merchant::API

  def provider
    ::PayPal::SDK.configure(
      mode: preferred_server.presence || "sandbox",
      username: preferred_login,
      password: preferred_password,
      signature: preferred_signature
    )
    provider_class.new
  end

  def purchase(_amount, express_checkout, _options = {})
    # GetExpressCheckoutDetails
    # DoExpressCheckoutPayment
    # store transaction_id
  end

  def refund(payment, amount)
    # RefundTransaction
    # update source
    # create negative payment
  end
end
```

Characteristics:

- Credentials are **NVP API username/password/signature**, stored per payment method.
- `provider` mutates global `PayPal::SDK` configuration on every call. This is not ideal in a multi-tenant, threaded application.
- `purchase` performs details lookup and capture in one step.
- `refund` operates on the NVP transaction ID.
- No explicit `authorize` / `capture` / `void` implementation; the integration relies on `purchase` and `refund`.
- The legacy gateway does not override `payment_source_class`; the controller assigns the source directly.

### 2.4 Source model and persistence

`Spree::PaypalExpressCheckout` is an empty ActiveRecord model. Its table contains:

```text
token                 # PayPal Express token
payer_id
transaction_id
state                 # default "complete"
refund_transaction_id
refunded_at
refund_type
```

### 2.5 Controller: `PaymentGateways::PaypalController`

```ruby
class PaypalController < BaseController
  include OrderStockCheck
  include OrderCompletion

  before_action :load_checkout_order, only: [:express, :confirm]
  before_action :handle_insufficient_stock, only: [:express, :confirm]
  before_action -> { check_order_cycle_expiry(...) }, only: [:express, :confirm]

  def express
    # build SetExpressCheckoutRequestDetails
    # provider.set_express_checkout
    # redirect to PayPal
  end

  def confirm
    # find pending PayPal payment
    # create source with token + PayerID
    # process_payment_completion!
  end

  def cancel
    # redirect back to checkout
  end
end
```

### 2.6 Payload builders

`Paypal::PaymentDetailsService` builds the NVP `PaymentDetails` hash:

- `OrderTotal`
- `ItemTotal`
- `ShippingTotal`
- `TaxTotal`
- `ShipToAddress`
- `PaymentDetailsItem`
- `ShippingMethod`
- `PaymentAction: "Sale"`
- `ShippingDiscount` for customer credit

`Paypal::ItemsBuilderService` builds NVP line items from:

- order line items;
- eligible non-tax/non-shipping adjustments;
- filtering out zero-dollar items.

### 2.7 Pending-payment lookup

`Orders::FindPaymentService#last_pending_paypal_payment` currently hardcodes:

```ruby
payment.payment_method&.type == "Spree::Gateway::PayPalExpress"
```

This must be generalized before a second PayPal type is enabled.

### 2.8 Runtime flow

```text
1. Shopper confirms order
   CheckoutController#confirm_order
     → selected_payment_method.external_gateway?
     → Gateway::PayPalExpress#external_payment_url
     → GET /paypal?payment_method_id=N

2. PaypalController#express
     → load order, stock check, order-cycle check
     → Paypal::PaymentDetailsService
     → provider.build_set_express_checkout
     → provider.set_express_checkout
     → redirect to PayPal

3. PayPal approval page

4. PayPal redirects back
   GET /paypal/confirm?token=...&PayerID=...
     → FindPaymentService#last_pending_paypal_payment
     → create Spree::PaypalExpressCheckout(token, payer_id)
     → OrderCompletion#process_payment_completion!
       → order.process_payments!
         → Gateway::PayPalExpress#purchase
           → GetExpressCheckoutDetails
           → DoExpressCheckoutPayment
           → source.update(transaction_id)
     → order complete, checkout reset

5. Admin refund
   POST /admin/orders/:order_id/payments/:id/paypal_refund
     → Gateway::PayPalExpress#refund
       → RefundTransaction
       → source.update(refunded_at, refund_transaction_id, state)
       → create negative payment
```

### 2.9 Current coupling and limitations

- Global `PayPal::SDK.configure` per request.
- SOAP-specific response objects (`RefundTransactionID`, `errors.first.long_message`).
- Hardcoded class check in `FindPaymentService`.
- Hardcoded legacy PayPal type in the admin PayPal payments controller.
- Admin refund flow assumes the old response shape.
- Report matches by payment method name containing `"PayPal"`.
- Tests are built around raw SOAP XML stubs.
- The CA monkey-patch exists only because the SDK bundles certificates.

---

## 3. Proposed REST implementation

### 3.1 Design principles

Keep the two integrations independent:

- two gateway classes;
- two controllers;
- two route sets;
- two source models/tables;
- two payload builders;
- one thin REST client adapter.

Share only stable domain behaviour:

- order loading and validation;
- stock and order-cycle checks;
- order completion;
- payment-method-scoped payment lookup;
- admin refund handling through a normalized result object.

Do **not** put `if legacy?` branches inside the existing gateway or controller.

### 3.2 High-level structure

```text
CheckoutController#redirect_to_payment_gateway
  └── Gateway::PayPalRest#external_payment_url
        └── GET /paypal/rest?payment_method_id=...

PaymentGateways::PaypalRestController
  ├── Orders::FindPaymentService (method-scoped)
  ├── PaypalRest::OrderRequestBuilderService
  │     └── PaypalRest::PurchaseUnitBuilderService
  │           └── PaypalRest::ItemsBuilderService
  ├── Gateway::PayPalRest#client
  │     └── PaypalRest::Client
  │           └── PaypalServerSdk::Client
  └── OrderCompletion / OrderStockCheck

Spree::Payment#process_payments!
  └── Gateway::PayPalRest#purchase
        └── PaypalRest::Client#capture_order

Admin refund
  └── PaymentsController#paypal_refund
        └── Gateway::PayPalRest#refund
              └── PaypalRest::Client#refund_capture
```

### 3.3 File map

```text
Gemfile
└── paypal-server-sdk (pinned)

config/routes.rb
└── /paypal/rest, /paypal/rest/confirm, /paypal/rest/cancel

app/models/spree/
├── gateway/pay_pal_rest.rb
└── paypal_rest_checkout.rb

app/controllers/payment_gateways/
└── paypal_rest_controller.rb

app/services/paypal_rest/
├── client.rb
├── result.rb
├── order_request_builder_service.rb
├── purchase_unit_builder_service.rb
└── items_builder_service.rb

app/views/
├── checkout/payment/_paypal_rest.html.haml
└── spree/admin/payments/
    ├── source_forms/_paypal_rest.html.haml
    └── source_views/_paypal_rest.html.haml

db/migrate/
└── ..._create_spree_paypal_rest_checkouts.rb
```

Tests:

```text
spec/support/request/paypal_rest_helper.rb
spec/controllers/payment_gateways/paypal_rest_controller_spec.rb
spec/models/spree/gateway/pay_pal_rest_spec.rb
spec/services/paypal_rest/...
spec/requests/checkout/paypal_rest_spec.rb
spec/system/consumer/shopping/checkout_paypal_rest_spec.rb
```

### 3.4 Gateway: `Spree::Gateway::PayPalRest`

Illustrative skeleton:

```ruby
module Spree
  class Gateway
    class PayPalRest < Gateway
      preference :client_id, :string
      preference :client_secret, :password
      preference :server, :string, default: "sandbox"
      preference :brand_name, :string
      preference :logo_url, :string

      def payment_source_class = Spree::PaypalRestCheckout
      def external_gateway? = true
      def method_type = "paypal_rest"

      def external_payment_url(_options)
        Rails.application.routes.url_helpers.
          payment_gateways_paypal_rest_express_path(payment_method_id: id)
      end

      def client
        @client ||= PaypalRest::Client.new(
          client_id: preferred_client_id,
          client_secret: preferred_client_secret,
          environment: preferred_server
        )
      end

      def purchase(_amount, source, _options = {})
        result = client.capture_order(source.order_id)

        if result.success?
          source.update!(
            capture_id: result.capture_id,
            payer_id: result.payer_id,
            status: result.status
          )
          PaypalRest::Result.success
        else
          result
        end
      end

      def refund(payment, amount)
        result = client.refund_capture(
          payment.source.capture_id,
          amount: amount,
          currency: payment.currency
        )

        if result.success?
          payment.source.update!(
            refund_id: result.refund_id,
            refunded_at: Time.zone.now,
            status: "refunded"
          )

          payment.class.create!(
            order: payment.order,
            source: payment,
            payment_method: payment.payment_method,
            amount: amount.to_f.abs * -1,
            response_code: result.refund_id,
            state: "completed"
          )
        end

        result
      end
    end
  end
end
```

> Skeletons are illustrative. Exact `paypal-server-sdk` response mapping and error handling must be verified during the implementation spike.

### 3.5 Source model: `Spree::PaypalRestCheckout`

Proposed table:

```text
spree_paypal_rest_checkouts
├── id
├── order_id          # PayPal order ID returned as `token`
├── capture_id        # PayPal capture ID, required for refunds
├── payer_id
├── status
├── refund_id
├── refunded_at
├── created_at
└── updated_at
```

Suggested indexes:

```ruby
index :order_id, unique: true
index :capture_id
```

### 3.6 REST client adapter: `PaypalRest::Client`

This is the anti-corruption layer around `paypal-server-sdk`. Keeping it small makes the gateway and controllers testable and isolates generated SDK types.

```ruby
module PaypalRest
  class Client
    def initialize(client_id:, client_secret:, environment:)
      @sdk = PaypalServerSdk::Client.new(
        client_credentials_auth_credentials:
          PaypalServerSdk::ClientCredentialsAuthCredentials.new(
            o_auth_client_id: client_id,
            o_auth_client_secret: client_secret
          ),
        environment: environment == "live" ?
          PaypalServerSdk::Environment::PRODUCTION :
          PaypalServerSdk::Environment::SANDBOX
      )
    end

    def create_order(payload)
      response = @sdk.orders.create_order(body: payload)
      normalize_order(response)
    end

    def capture_order(order_id)
      response = @sdk.orders.capture_order(id: order_id, body: {})
      normalize_capture(response)
    end

    def refund_capture(capture_id, amount:, currency:)
      response = @sdk.payments.refund_captured_payment(
        capture_id: capture_id,
        body: {
          amount: {
            value: format("%.2f", amount),
            currency_code: currency
          }
        }
      )
      normalize_refund(response)
    end
  end
end
```

Normalized result objects should expose at least:

```ruby
result.success?
result.error_message
result.to_s
```

For orders/captures:

```ruby
result.order_id
result.capture_id
result.payer_id
result.status
result.approval_url
```

For refunds:

```ruby
result.refund_id
result.status
```

### 3.7 Payload builders

`PaypalRest::OrderRequestBuilderService` builds the complete `PaypalServerSdk::OrderRequest`:

```ruby
{
  intent: "CAPTURE",
  purchase_units: [purchase_unit],
  payment_source: {
    paypal: {
      experience_context: {
        return_url: confirm_url,
        cancel_url: cancel_url,
        user_action: "PAY_NOW",
        shipping_preference: address_required ? "GET_FROM_FILE" : "NO_SHIPPING"
      }
    }
  }
}
```

`PaypalRest::PurchaseUnitBuilderService` builds the purchase unit:

```ruby
{
  invoice_id: order.number,
  amount: {
    currency_code: order.currency,
    value: last_payment.amount.to_s,
    breakdown: {
      item_total: { currency_code:, value: item_sum },
      shipping: { currency_code:, value: order.ship_total },
      tax_total: { currency_code:, value: tax_total },
      discount: { currency_code:, value: customer_credit }
    }
  },
  items: PaypalRest::ItemsBuilderService.new(order).call,
  shipping: address_options
}
```

`PaypalRest::ItemsBuilderService` returns REST items:

```ruby
{
  name: item.product.name,
  sku: item.variant.sku,
  quantity: item.quantity.to_s,
  unit_amount: {
    currency_code: order.currency,
    value: item.price.to_s
  },
  category: "PHYSICAL_GOODS"
}
```

### 3.8 Controller: `PaymentGateways::PaypalRestController`

```ruby
module PaymentGateways
  class PaypalRestController < BaseController
    include OrderStockCheck
    include OrderCompletion

    before_action :load_checkout_order, only: [:express, :confirm]
    before_action :handle_insufficient_stock, only: [:express, :confirm]
    before_action -> { check_order_cycle_expiry(...) }, only: [:express, :confirm]

    def express
      # build REST order payload
      # client.create_order
      # redirect to approval URL
    end

    def confirm
      # find pending payment for this payment method
      # create PaypalRestCheckout(order_id: params[:token], payer_id: params[:PayerID])
      # process_payment_completion!
    end

    def cancel
      # redirect back to checkout
    end
  end
end
```

### 3.9 Routes

```ruby
namespace :payment_gateways do
  # legacy, unchanged
  get "/paypal",         to: "paypal#express", as: :paypal_express
  get "/paypal/confirm", to: "paypal#confirm", as: :confirm_paypal
  get "/paypal/cancel",  to: "paypal#cancel",  as: :cancel_paypal

  # new
  get "/paypal/rest",         to: "paypal_rest#express", as: :paypal_rest_express
  get "/paypal/rest/confirm", to: "paypal_rest#confirm", as: :confirm_paypal_rest
  get "/paypal/rest/cancel",  to: "paypal_rest#cancel",  as: :cancel_paypal_rest
end
```

### 3.10 Runtime flow

```text
1. Shopper confirms order
   CheckoutController#confirm_order
     → selected_payment_method.external_gateway?
     → Gateway::PayPalRest#external_payment_url
     → GET /paypal/rest?payment_method_id=N

2. PaypalRestController#create
     → load order, stock check, order-cycle check
     → PaypalRest::OrderRequestBuilderService
       → PaypalRest::PurchaseUnitBuilderService
         → PaypalRest::ItemsBuilderService
     → PaypalRest::Client#create_order
     → redirect to PayPal approval URL

3. PayPal approval page

4. PayPal redirects back
   GET /paypal/rest/confirm?token=ORDER_ID&PayerID=...
     → FindPaymentService#last_pending_payment_for(payment_method)
     → create Spree::PaypalRestCheckout(
         order_id: params[:token],
         payer_id: params[:PayerID]
       )
     → OrderCompletion#process_payment_completion!
       → order.process_payments!
         → Gateway::PayPalRest#purchase
           → PaypalRest::Client#capture_order(order_id)
           → source.update(capture_id, payer_id, status)
     → order complete, checkout reset

5. Admin refund
   POST /admin/orders/:order_id/payments/:id/paypal_refund
     → Gateway::PayPalRest#refund
       → PaypalRest::Client#refund_capture(capture_id, amount)
       → source.update(refund_id, refunded_at, status)
       → create negative payment
```

---

## 4. API mapping: legacy vs REST

| Concern | Legacy NVP/SOAP | REST |
|---|---|---|
| Start checkout | `SetExpressCheckout` | `POST /v2/checkout/orders` |
| Buyer details | `GetExpressCheckoutDetails` | `GET /v2/checkout/orders/{id}` (often unnecessary) |
| Capture | `DoExpressCheckoutPayment` | `POST /v2/checkout/orders/{id}/capture` |
| Refund | `RefundTransaction` | `POST /v2/payments/captures/{capture_id}/refund` |
| Checkout token | PayPal Express token | PayPal order ID |
| Payer ID | `PayerID` | `payer.payer_id` |
| Transaction reference | `transaction_id` | capture ID |
| Credentials | login/password/signature | client ID/client secret |
| Transport | SOAP/XML | REST/JSON |

---

## 5. Shared vs separate code

| Concern | Current | Proposed coexistence |
|---|---|---|
| Gateway class | `PayPalExpress` | keep as-is |
| New gateway | — | `PayPalRest` |
| Controller | `PaypalController` | keep; add `PaypalRestController` |
| Routes | `/paypal/*` | keep; add `/paypal/rest/*` |
| Source model | `PaypalExpressCheckout` | keep; add `PaypalRestCheckout` |
| Credentials | login/password/signature | client ID/client secret |
| SDK | `paypal-sdk-merchant` | `paypal-server-sdk` + `PaypalRest::Client` |
| Payload builders | NVP hashes | REST JSON |
| Capture | `DoExpressCheckoutPayment` | `Orders#capture_order` |
| Refund | `RefundTransaction` | `Payments#refund_captured_payment` |
| Error shape | SOAP `long_message` | REST/SDK errors |
| Checkout partial | `_paypal` | add `_paypal_rest` |
| Admin source views | `_paypal` | add `_paypal_rest` |
| Order completion | `OrderCompletion` | reuse unchanged |
| Stock/order-cycle checks | `OrderStockCheck` | reuse unchanged |
| Pending payment lookup | hardcoded legacy type | generalize to payment-method scope |
| Admin refund | old response assumptions | normalize both responses |
| Reports | name contains `"PayPal"` | keep naming or switch to type-based |

---

## 6. Shared gateway contract

Both gateways should expose:

```ruby
external_gateway?          # true
external_payment_url(...)  # route to their own controller
method_type                # "paypal" / "paypal_rest"
purchase(amount, source, options)
refund(payment, amount)
payment_source_class       # legacy: PaypalExpressCheckout
                           # new:    PaypalRestCheckout
```

Both source models should expose enough for admin display and refund:

```ruby
payer_id
token / order_id
transaction_id / capture_id
refunded_at
```

---

## 7. Coexistence plan summary

### 7.1 Why run both at once

- Legacy refunds remain available for historical NVP payments.
- In-flight legacy checkouts keep working during and after deployment.
- Enterprises can migrate credentials gradually.
- Rollback is simple: deactivate the new payment method and keep using the old one.

### 7.2 Configuration model

- Existing payment methods keep `type = "Spree::Gateway::PayPalExpress"` and their NVP credentials.
- Migrating enterprises create a **new** payment method of type `Spree::Gateway::PayPalRest` with REST client ID/secret.
- Do **not** convert existing payment method records in place.
- After the new method is verified, deactivate the legacy one.

### 7.3 Feature flag

Add `paypal_rest` to `OpenFoodNetwork::FeatureToggle::CURRENT_FEATURES` and hide the new provider from the admin provider dropdown until enabled for the relevant instance/enterprise.

The flag should control creation/visibility, not break already-created new payment methods.

### 7.4 Avoid duplicate checkout options

Both gateways can technically be active for the same distributor, which would show two PayPal options. Operational rule:

- create and test the new method;
- deactivate the legacy method once the new one is live.

Consider an admin warning, but avoid a hard validation because payment methods can be shared across distributors.

### 7.5 Legacy removal criteria

Do not remove the legacy gateway immediately after the last enterprise migrates. Historical `Spree::Payment` records still reference `Spree::Gateway::PayPalExpress` and `Spree::PaypalExpressCheckout`.

Safe removal sequence:

1. Stop creating new legacy payment methods.
2. Deactivate legacy methods after each enterprise migrates.
3. Keep the legacy gateway, routes, controller, source model and gem until:
   - no pending legacy checkouts remain;
   - all legacy payments are outside the PayPal refund window (currently 180 days) or refunds have been handled.
4. Then:
   - remove the legacy provider from `PAYMENT_METHODS`;
   - remove legacy routes/controller;
   - strip `purchase` / `refund` / `provider` and `require "paypal-sdk-merchant"` from the legacy gateway;
   - delete `config/initializers/paypal.rb`;
   - remove `paypal-sdk-merchant` from the Gemfile;
   - keep the legacy source model/table and a read-only source view for historical records, or archive/migrate those records.

---

## 8. Estimated effort

Assumes one developer familiar with OFN, sandbox credentials available, and no UX redesign.

| Work | Estimate |
|---|---|
| REST client wrapper + gateway | 2–3 days |
| New controller, routes and source model | 2–3 days |
| Payment details/items builders | 1–2 days |
| Shared refactors (payment lookup, refund adapter, provider list, report) | 1–2 days |
| Tests (new + legacy regression) | 3–4 days |
| Feature flag, pilot, docs, rollout support | 1–2 days |
| **Total** | **10–16 dev days (~2.5–3 weeks)** |

Add 3–5 days if webhooks, dual-gateway in-flight handling, or automated credential migration are included.

---

## 9. Points to verify during implementation spike

- Exact `paypal-server-sdk` response and error classes for create/capture/refund.
- Whether legacy NVP transaction IDs can be used as REST capture IDs for refunds. If not, keep the legacy gateway until the refund window expires.
- PayPal Orders v2 currency support for every instance currency.
- Amount rounding and breakdown totals for vouchers, customer credit, shipping and tax.
- Behaviour for zero-dollar items and zero-priced orders.
- Sandbox approval/return parameters (`token`, `PayerID`).
- Error messages for declined payments, expired orders and duplicate captures.
- Thread-safety and credential isolation when multiple enterprises use different PayPal accounts.
- Whether the SDK logs sensitive request data and how to disable/redact it.

---

## 10. References

- Issue: <https://github.com/openfoodfoundation/openfoodnetwork/issues/5857>
- Original certificate issue: <https://github.com/openfoodfoundation/openfoodnetwork/issues/5855>
- PayPal Server SDK: <https://github.com/paypal/PayPal-Ruby-Server-SDK>
- PayPal Orders v2 API: <https://developer.paypal.com/docs/api/orders/v2/>
- PayPal Payments v2 API: <https://developer.paypal.com/docs/api/payments/v2/>
- NVP/SOAP to REST upgrade guide: <https://developer.paypal.com/upgrade/ec/guide/Express%20Checkout%20Authorization/>
- Deprecated SDKs:
  - <https://rubygems.org/gems/paypal-sdk-merchant>
  - <https://rubygems.org/gems/paypal-checkout-sdk>
