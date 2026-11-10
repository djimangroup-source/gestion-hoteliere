-- 77b · public_venues écrit (limitation de débit) : fonction volatile, sinon refusée en lecture seule par l'API.
alter function public.public_venues(text) volatile;
