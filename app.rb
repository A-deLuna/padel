require 'pry'
require 'active_support'
require 'active_support/all'
require 'excon'


module Padel
  class Error < ::StandardError; end
  class BookedError < Error; end
end

url = 'https://playtomic.io'
$conn = Excon.new(
  url, 
  debug: true,
  persistent: true,
  retry_errors: [
    Excon::Error::Timeout,
    Excon::Error::Socket,
    Excon::Error::Unauthorized,
  ])
# ACTION: Find this token in playtomic's Web App by inspecting browser requests on their web app.
# It's a JWT.
$token = 'TOKEN'

# Creo que esto era el identificador del padel norte, pero ya no me acuerdo.
$tenant_id ='1156bc08-bbbe-40a7-99f5-f8a87a11a02e'
class Opening
  attr_reader :timestamp
  attr_reader :slots

  def initialize(timestamp:, slots:)
    @timestamp = timestamp
    @slots = slots
    @slots.each {|s| s.opening = self }
  end

  def durations
    slots.map(&:durations).map(&:to_set).inject(:+).to_a
  end

  def inspect
    "<Opening: #{timestamp.strftime '%a %F, %H:%M' }, #{durations}>"
  end

  def book duration:
    available = slots.select do |s|
      s.durations.any? duration
    end
    raise Padel::Error if available.empty?

    available.each do |slot|
      p "trying to book #{slot.resource_id} on #{timestamp} for #{duration} minutes"
      slot.book duration: duration
      return
    rescue Padel::BookedError
    end
  end
end

class Slot
  attr_accessor :opening
  attr_reader :resource_id
  attr_reader :durations

  def initialize(resource_id:, durations:)
    @resource_id = resource_id
    @durations = durations
  end

  def book duration:
    resp = payment_intents slot:self, duration: duration
    payment_intent slot:self, duration: duration, **resp
    confirmation_details = confirmation intent_id: resp[:intent_id]
    match_details = match match_id: resp[:match_id]
  end
end

def parse times
  times.map do |t|
    slots = t['courts'].map do |k, v|
      Slot.new(resource_id: k, durations: v["duration"])
    end
    Opening.new(timestamp: t["timestamp"], slots: slots)
  end.to_h do |opening|
    [opening.timestamp.strftime('%H:%M'), opening]
  end
end

def times (days = 0)
  time = days.days.from_now
  path = '/api/v1/availability'
  query = {
    'tenant_id': '1156bc08-bbbe-40a7-99f5-f8a87a11a02e',
    'sport_id': 'PADEL',
    'local_start_min': time.strftime('%FT00:00:00'),
    'local_start_max': time.strftime('%FT23:59:59'),
    'user_id': 'me',
  }
  params = {
    path: path,
    query: query,
    headers: {Authorization: "Bearer #{$token}"},
    idempotent: true,
  }
  resp = $conn.get( **params)
  while resp.status == 401
    p "retrying"
    resp = $conn.get(** params)
  end
  resp = JSON.parse resp.body
  h = {}
  resp.each do |entry|
    entries = entry["slots"].map do |s|
      s.tap do |s|
        s["resource_id"] = entry["resource_id"]
        s["start_date"] = entry["start_date"]
        utc = Time.parse(entry["start_date"] + "T" + s["start_time"] + "UTC")
        s["timestamp"] = utc.in_time_zone("America/Los_Angeles")
        s["price"] = [s["price"]]
        s["duration"] = [s["duration"]]
      end
    end

    entries.each do |entry|
      key = entry["timestamp"]
      if h.key? (key)
        if h[key]["courts"].key?  entry["resource_id"]
          h[key]["courts"][entry["resource_id"]]["price"] += entry["price"]
          h[key]["courts"][entry["resource_id"]]["duration"] += entry["duration"]
        else
        h[key]["courts"][entry["resource_id"]] = {
          "price" => entry["price"],
          "duration" => entry["duration"],
        }
        end 
      else
        entry["courts"] = { entry["resource_id"] => {
          "price" => entry["price"],
          "duration" => entry["duration"],
        }}
        entry.delete("price")
        entry.delete("duration")
        entry.delete("resource_id")
        h[key] = entry
      end
    end
  end
  resp = h.values.sort_by do |entry|
    entry["timestamp"]
  end
  parse resp
end


def payment_intents slot:, duration: 
  path = '/api/v1/payment_intents'
  body = {
    "allowed_payment_method_types": [
      "OFFER",
      "CASH",
      "MERCHANT_WALLET",
      "DIRECT",
      "SWISH",
      "IDEAL",
      "BANCONTACT",
      "PAYTRAIL",
      "CREDIT_CARD",
      "QUICK_PAY"
    ],
    # ACTION: substitute this for your account user id.
    # Try booking a court from their web UI and inspect their requests.
    # Mine was a 7 digit decimal number.
    "user_id":"USER_ID",
    "cart":{
      "requested_item":{
        "cart_item_type":"CUSTOMER_MATCH",
        "cart_item_voucher_id":nil,
        "cart_item_data":{
          "supports_split_payment":true,
          "number_of_players":4,
          "tenant_id":"#{$tenant_id}",
          "resource_id":"#{slot.resource_id}",
          "start":"#{slot.opening.timestamp.utc.strftime '%FT%H:%M:%S'}",
          "duration": duration,
          "match_registrations":[ 
            {
              #ACTION: same as above
              "user_id":"USER_ID",
              "pay_now":true
            }
          ]
        }
      }
    }
  }.to_json
  
  headers = {
    Authorization: "Bearer #{$token}",
    'Content-Type': 'application/json',
  }

  params = {
    path: path,
    body: body,
    headers: headers
  }

  resp = $conn.post(**params)
  while resp.status == 401
    p "retrying"
    resp = $conn.post(** params)
  end

  raise Padel::BookedError if resp.status == 409

  intent = JSON.parse resp.body
  return {
    intent_id: intent["payment_intent_id"],
    payment_method_id: intent["available_payment_methods"][0]["payment_method_id"],
    match_id: intent["cart"]["item"]["cart_item_id"],
  }
end


def payment_intent slot:, duration:,  payment_method_id:, intent_id:, **rest
  path = "/api/v1/payment_intents/#{intent_id}"
  headers = {
    Authorization: "Bearer #{$token}",
    'Content-Type': 'application/json',
  }

  queryparam = [
    $tenant_id,
    slot.resource_id,
    slot.opening.timestamp.utc.strftime('%FT%H:%M'),
    duration,
    intent_id
  ].join('~')
  body = {
    "selected_payment_method_id": payment_method_id,
    "selected_payment_method_data": {
      "stripe_return_url":"https://playtomic.io/checkout/booking?s=#{CGI.escape queryparam}&r=y"
    }
  }.to_json

  params = {
    path: path,
    body: body,
    headers: headers
  }

  resp = $conn.patch(**params)
  while resp.status == 401
    p "retrying"
    resp = $conn.patch(** params)
  end
end

def confirmation intent_id: 
  path = "/api/v1/payment_intents/#{intent_id}/confirmation"
  headers = {
    Authorization: "Bearer #{$token}",
    'Content-Type': 'application/json',
  }
  params = {
    path: path,
    headers: headers
  }

  resp = $conn.post(**params)
  while resp.status == 401
    p "retrying"
    resp = $conn.post(**params)
  end
  resp.body
end

def match match_id:
  path = "/api/v1/matches/#{match_id}"
  headers = {
    Authorization: "Bearer #{$token}",
    'Content-Type': 'application/json',
  }
  params = {
    path: path,
    headers: headers
  }
  resp = $conn.get(**params)
  while resp.status == 401
    p "retrying"
    resp = $conn.get(**params)
  end
end

# Remember using this during development. Probably copy pasted
# the response from the console request inspector.
# Redacted away some things that might be PII
def mock_payment_intents
  resp = %(
{
    "payment_intent_id": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "payment_intent_reference": null,
    "payment_intent_provider": null,
    "user_id": "0123456",
    "price": "454.9 MXN",
    "commission": "4.9 MXN",
    "refund_commission": null,
    "full_refund_duration": {
        "amount": 0,
        "unit": "HOURS"
    },
    "status": "REQUIRES_PAYMENT_METHOD",
    "available_payment_methods": [
        {
            "payment_method_id": "CREDIT_CARD-STRIPE_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "name": "Pay with card **** **** **** 0123",
            "method_type": "CREDIT_CARD",
            "data": {
                "card_id": "STRIPE_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "masked_card_number": "**** **** **** 0123",
                "type": "VISA",
                "provider": "STRIPE",
                "validated": true,
                "exp_month": 01,
                "exp_year": 2034,
                "expired": false
            }
        },
        {
            "payment_method_id": "QUICK_PAY",
            "name": "Quick pay",
            "method_type": "QUICK_PAY",
            "data": null
        }
    ],
    "selected_payment_method_id": null,
    "selected_payment_method_data": null,
    "next_payment_action": null,
    "next_payment_action_data": null,
    "cart": {
        "item": {
            "cart_item_id": "07ce0089-10ec-458b-a07e-7c2cdc3881ae",
            "cart_item_type": "CUSTOMER_MATCH",
            "cart_item_tenant_id": "1156bc08-bbbe-40a7-99f5-f8a87a11a02e",
            "description": "Match - 8/23/22, 9:00 AM",
            "price": "450 MXN",
            "cart_item_data": {
                "match_id": "07ce0089-10ec-458b-a07e-7c2cdc3881ae",
                "reservation_id": "535059e6-b2ae-49af-a0d4-3842b574d69e",
                "temporal_lock_id": null,
                "match_registrations": [
                    {
                        "user_id": "0123456",
                        "contact_id": null,
                        "price": "450 MXN",
                        "custom_price": null,
                        "pay_now": true,
                        "product_extras_info": null,
                        "applied_benefits_info": null
                    }
                ],
                "sport_id": "PADEL",
                "start": "2022-08-23T16:00:00",
                "zone_id": "America/Tijuana",
                "duration": 60,
                "resource_id": "1dadfe58-e63c-41ec-aa76-a7b40a7596bb",
                "resource_properties": {
                    "resource_type": "outdoor",
                    "resource_size": "double",
                    "resource_feature": "panoramic"
                },
                "client": "WEB_DESKTOP",
                "split_payment_parts": 1,
                "supports_split_payment": true,
                "number_of_players": 4,
                "product_type": "CUSTOMER_MATCH",
                "split_payment_allowed": true,
                "supported_payment_plans": [
                    "SPLIT",
                    "SINGLE_PAYER"
                ]
            },
            "cart_item_voucher_id": null,
            "supported_merchant_payment_method_ids": null
        },
        "voucher_id": null,
        "price": "450 MXN"
    },
    "fail_reason": null,
    "payment_id": null,
    "created_at": "2022-08-16T16:14:15",
    "last_modified": "2022-08-16T16:14:15",
    "payment_source": "WEB_DESKTOP",
    "keep_payment_commission_inside_grace_period": null,
    "keep_payment_commission_outside_grace_period": null,
    "subscription_id": null,
    "commission_saved_up": null,
    "stripe_public_key": "pk_live_DDDDDDDDDDDDDDDDDDDDDDDD",
    "payment_provider_account_id": "Stripe_ES"
  })
  return JSON.parse resp
end


module LambdaFunction
  class Handler
    def self.process(event:, context:)
      p "Time: #{Time.now}"
      days_ahead = 6
      openings = times days_ahead
      p "Openings: #{openings}"
      desired_time = '19:30'
      desired_duration = 90
      while  !openings.key? desired_time
        p "did not find opening for desired time, sleeping"
        sleep(1)
        openings = times days_ahead
        p "Openings: #{openings}"
      end

      opening = openings[desired_time]

      if !opening.durations.include? desired_duration
        p "there is no desired booking option"
        return
      end

      opening.book duration: 90
    end
  end
end


#binding.pry 
