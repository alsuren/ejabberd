
-- There are only 9 valid states in http://tools.ietf.org/html/rfc6121#appendix-A
-- Numbers match up with those in "A.1. Defined States".
select
  ru.username,
  ru.jid,
  ru.subscription,
  ru.ask
from
  ejabberd.rosterusers ru
where
  not
  (
    (ru.subscription = 'N' and ru.ask = 'N') -- 1.
    or
    (ru.subscription = 'N' and ru.ask = 'O') -- 2.
    or
    (ru.subscription = 'N' and ru.ask = 'I') -- 3.
    or
    (ru.subscription = 'N' and ru.ask = 'B') -- 4.
    or
    (ru.subscription = 'T' and ru.ask = 'N') -- 5.
    or
    (ru.subscription = 'T' and ru.ask = 'I') -- 6.
    or
    (ru.subscription = 'F' and ru.ask = 'N') -- 7.
    or
    (ru.subscription = 'F' and ru.ask = 'O') -- 8.
    or
    (ru.subscription = 'B' and ru.ask = 'N') -- 9.
  )
limit 10
  ;

-- Subscriptions within pairs of users on the local server happen in well-defined pairs.
-- See git commit message for a full explaination
select
  ru1.username as us,
  ru1.jid as them,
  ru1.subscription as our_subs,
  ru1.ask as our_ask,
  ru2.subscription as their_subs,
  ru2.ask as their_ask
from
  ejabberd.rosterusers ru1,
  ejabberd.rosterusers ru2
where
  substring_index(ru1.jid, '@', -1) = 'YOUR.DOMAIN.HERE'
  and
  substring_index(ru1.jid, '@', 1) = ru2.username
  and
  substring_index(ru2.jid, '@', -1) = 'YOUR.DOMAIN.HERE'
  and
  substring_index(ru2.jid, '@', 1) = ru1.username
  and
  (
    (ru1.subscription = 'N' and ru1.ask = 'N' and (ru2.subscription <> 'N' or ru2.ask <> 'N')) -- 0
    or
    (ru1.subscription = 'N' and ru1.ask = 'I' and (ru2.subscription <> 'N' or ru2.ask <> 'O')) -- 1
    or
    (ru1.subscription = 'N' and ru1.ask = 'O' and (ru2.subscription <> 'N' or ru2.ask <> 'I')) -- 1
    or
    (ru1.subscription = 'N' and ru1.ask = 'B' and (ru2.subscription <> 'N' or ru2.ask <> 'B')) -- 2
    or
    (ru1.subscription = 'T' and ru1.ask = 'I' and (ru2.subscription <> 'F' or ru2.ask <> 'O')) -- 3
    or
    (ru1.subscription = 'F' and ru1.ask = 'O' and (ru2.subscription <> 'T' or ru2.ask <> 'I')) -- 3
    or
    (ru1.subscription = 'T' and ru1.ask = 'N' and (ru2.subscription <> 'F' or ru2.ask <> 'N')) -- 2b
    or
    (ru1.subscription = 'F' and ru1.ask = 'N' and (ru2.subscription <> 'T' or ru2.ask <> 'N')) -- 2b
    or
    (ru1.subscription = 'B' and ru2.subscription <> 'B') -- 4
  )

limit 10 -- Probably best to run this query on a replica, because it's pretty expensive.
  ;
