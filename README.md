# Padel
Sharing code I used for automatically booking padel matches in playtomic.

My setup was a ruby lambda and used something in AWS for starting the lambda
automatically between M-F at around 7:29 pm.

# Development
The way I developed this was by booking a match through their WebUI and
keeping the network inspector tab open. Copy pasting some request/responses.

As many companies do now, they set a JWT access token as a cookie when you
log in. If I recall correctly the token lasts for about ~3 months. So you can
have this running uninterrupted for periods of 3 months. And log in occassionally
to get a new JWT.

## Setup
Added `# ACTION` comments on the code on places you need to substitute values.
Mostly, it's the JWT and User ID that you can find by logging in to the web page
and ispecting a bit of traffic.

### Ruby & bundle
Install ruby, see use `rbenv`.

cd into the directory and run `bundle`. Will install gems.

## Getting started
Once you substituted the #ACTION comments you can play with the API
from the command line.

Uncomment last line in app.rb `#binding.pry`

run `bundle exec ruby ./app.rb`

It will load the code and let you play with it from the command line.

Try doing `times 6` and see what you get.

## What's going on

I don't remember exactly what it does but sharing notes in case it's useful
for the next person.

### #times
The `times` function requests all the avaliable time slots in a court. It
takes a parameter `days` and it will try to find all the slots available in a
particular day. I think their `/availability` API uses UTC time zone, but not sure
anymore. Don't remember why I'm pulling only a 24 hour period. Can't remember
if it's an API limitation or just something I didn't think of doing differently.

I think the purpose of this function was to collapse the response data in a way
we can search by time and duration.

Seems that it returns a hash of {time => Opening object}. 

### Opening#book

Iterates through all the slots open for at time T. Checks if there's
a slot open of the desired duration.

One by one tries to book the slot. In practice this will be one of many
courts. We rescue the error because someone else might beat us to booking
this court and we want to try with the next.


### Slot#book
Calls payment intents. I think this returns a payment intent object, which
is like a new payment transction for a particular court at a particular time.
I think that if this succeeds the court stops being available for everyone else.
It's like when in the app you start booking it gives you a few minutes to complete
your payment and keeps your reservation.
:w
The payment intent response has a list of payment methods. The code just grabs the
first one, but if you have more than one card you might want to add extra logic
to handle the different responses.

I have no clue why the calls to payment_intent and confirmation are needed. But
This used to work!




