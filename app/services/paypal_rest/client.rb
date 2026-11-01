# frozen_string_literal: true

module PaypalRest
  class Client
    def initialize(client_id:, client_secret:, environment:)
      @sdk = PaypalServerSdk::Client.new(
        client_credentials_auth_credentials:
          PaypalServerSdk::ClientCredentialsAuthCredentials.new(
            o_auth_client_id: client_id,
            o_auth_client_secret: client_secret
          ),
        environment:
          if environment == "live"
            PaypalServerSdk::Environment::PRODUCTION
          else
            PaypalServerSdk::Environment::SANDBOX
          end
      )
    end

    def create_order(order_request, request_id: nil)
      options = { "body" => order_request, "paypal_request_id" => request_id }.compact
      normalize_order(@sdk.orders.create_order(options))
    rescue PaypalServerSdk::APIException, SocketError => e
      failure(e.message)
    end

    def capture_order(order_id, order_capture_request = {}, request_id: nil)
      options = {
        "id" => order_id, "body" => order_capture_request, "paypal_request_id" => request_id
      }.compact
      normalize_capture(@sdk.orders.capture_order(options))
    rescue PaypalServerSdk::APIException, SocketError => e
      failure(e.message)
    end

    def refund_capture(capture_id, refund_request, request_id: nil)
      options = {
        "capture_id" => capture_id, "body" => refund_request, "paypal_request_id" => request_id
      }.compact
      normalize_refund(@sdk.payments.refund_captured_payment(options))
    rescue PaypalServerSdk::APIException, SocketError => e
      failure(e.message)
    end

    private

    def normalize_order(response)
      return failure_from(response) unless response&.success?

      order = response.data
      return failure("PayPal did not return an order ID") if order&.id.blank?

      approval_link = Array(order.links).find do |link|
        %w[approve payer-action].include?(link.rel)
      end

      Result.new(
        success: true,
        order_id: order.id,
        approval_url: approval_link&.href,
        status: order.status
      )
    end

    def normalize_capture(response)
      return failure_from(response) unless response&.success?

      order = response.data
      capture = capture_from(order)

      unless capture&.status == PaypalServerSdk::CaptureStatus::COMPLETED
        return failure("PayPal capture status: #{capture&.status || 'unknown'}")
      end

      return failure("PayPal did not return a capture ID") if capture.id.blank?

      capture_result(order, capture)
    end

    def capture_from(order)
      purchase_unit = order.purchase_units&.first
      Array(purchase_unit&.payments&.captures).first
    end

    def capture_result(order, capture)
      Result.new(
        success: true,
        order_id: order.id,
        capture_id: capture.id,
        payer_id: order.payer&.payer_id,
        status: capture.status
      )
    end

    def normalize_refund(response)
      return failure_from(response) unless response&.success?

      refund = response.data

      unless refund&.status == PaypalServerSdk::RefundStatus::COMPLETED
        return failure("PayPal refund status: #{refund&.status || 'unknown'}")
      end

      return failure("PayPal did not return a refund ID") if refund.id.blank?

      Result.new(
        success: true,
        refund_id: refund.id,
        status: refund.status
      )
    end

    def failure_from(response)
      message =
        if response.respond_to?(:errors) && response.errors.present?
          Array(response.errors).join(" ")
        elsif response&.data.respond_to?(:message)
          response.data.message
        end

      failure(message)
    end

    def failure(message)
      Result.new(success: false, error_message: message.presence || "PayPal request failed")
    end
  end
end
