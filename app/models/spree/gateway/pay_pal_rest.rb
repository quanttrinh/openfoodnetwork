# frozen_string_literal: true

module Spree
  class Gateway
    class PayPalRest < Gateway
      preference :client_id, :string
      preference :client_secret, :password
      preference :server, :string, default: "sandbox"
      preference :solution, :string, default: "Mark"

      def client
        @client ||= PaypalRest::Client.new(
          client_id: preferred_client_id,
          client_secret: preferred_client_secret,
          environment: preferred_server
        )
      end

      def external_gateway?
        true
      end

      def external_payment_url(_options)
        Rails.application.routes.url_helpers.
          payment_gateways_paypal_rest_path(payment_method_id: id)
      end

      def supports?(_source)
        true
      end

      def method_type
        'paypal_rest'
      end

      def payment_source_class
        Spree::PaypalRestCheckout
      end

      def purchase(_amount, source, _gateway_options = {})
        return failed_purchase("Missing PayPal order ID") if source&.order_id.blank?

        result = client.capture_order(
          source.order_id,
          {},
          request_id: "ofn-capture-#{source.order_id}"
        )

        if result.success? && result.capture_id.present?
          source.update!(
            capture_id: result.capture_id,
            payer_id: result.payer_id,
            status: result.status
          )

          ActiveMerchant::Billing::Response.new(
            true,
            "PayPal capture #{result.status}",
            {},
            authorization: result.capture_id
          )
        else
          failed_purchase(
            result.error_message.presence || "PayPal did not return a capture ID"
          )
        end
      end

      def refund(payment, amount)
        capture_id = payment.source&.capture_id
        return failed_refund("Missing PayPal capture ID") if capture_id.blank?

        result = client.refund_capture(
          capture_id,
          refund_request(payment, amount),
          request_id: refund_request_id(payment, amount)
        )

        record_refund(payment, result, amount) if result.success?
        result
      end

      private

      def refund_request(payment, amount)
        {
          amount: {
            value: format("%.2f", amount),
            currency_code: payment.currency
          }
        }
      end

      def refund_request_id(payment, amount)
        "ofn-refund-#{payment.id}-#{format('%.2f', amount)}"
      end

      def record_refund(payment, result, amount)
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

      def failed_purchase(message)
        ActiveMerchant::Billing::Response.new(false, message)
      end

      def failed_refund(message)
        PaypalRest::Result.new(success: false, error_message: message)
      end
    end
  end
end
