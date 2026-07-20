-- ============================================================
-- C-DIRECT — TOUT LE SQL EN ATTENTE (à exécuter en une fois)
-- Copiez TOUT ce fichier, collez dans Supabase > SQL Editor,
-- puis cliquez Run. Sans danger : idempotent, ne supprime rien.
-- Regroupe sql/13 + sql/14 + sql/15.
-- ============================================================

-- ========== 13 : distance (code postal pharmacie) ==========
-- =====================================================================
-- C-DIRECT · SQL 13 — CODE POSTAL DE LA PHARMACIE DANS LES RPC DE LECTURE
-- À exécuter dans Supabase → SQL Editor (idempotent : create or replace).
--
-- Pourquoi : Phase 2.3 (distance + estimation km / per diem / hébergement).
-- Le tableau et la fiche calculent la distance FSA entre le code postal du
-- pharmacien (son profil) et celui de la pharmacie. La RLS empêche un
-- pharmacien de lire le profil d'une pharmacie ; ces RPC security definer
-- exposent donc UNIQUEMENT le code postal (comme elles exposent déjà
-- ville + logiciel), jamais le reste du profil.
--
-- Sans ce fichier, l'interface fonctionne quand même : elle affiche
-- l'estimation de base (tarif × heures) et masque simplement les lignes
-- de distance. Après exécution, les km + indemnités s'activent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- get_contrats_ouverts — + code_postal de la pharmacie
-- ---------------------------------------------------------------------
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (public.mon_role() in ('pharmacien','admin')) then
    raise exception 'Accès refusé';
  end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, p.ville, p.logiciel, p.code_postal,
           exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- get_contrat_fiche — + code_postal de la pharmacie
-- ---------------------------------------------------------------------
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text, code_postal text,
  ma_candidature_statut text, est_ma_pharmacie boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.rx_jour_semaine, k.rx_jour_weekend,
           k.seul_pharmacien, k.atp_presente, k.services,
           k.notes, k.statut, k.created_at,
           p.ville, p.logiciel, p.code_postal,
           (select c.statut from public.candidatures c
             where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           (k.pharmacie_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.numero_reference = upper(trim(p_ref))
       and (
         public.est_admin()
         or k.pharmacie_id = auth.uid()
         or (public.mon_role() = 'pharmacien'
             and (k.statut = 'ouvert' or public.a_postule(k.id)))
       );
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ========== 14 : FSA + comptage compatibles ==========
-- =====================================================================
-- C-DIRECT · SQL 14 — FSA (centroïdes) + distance + comptage compatibles
-- À exécuter dans Supabase → SQL Editor (idempotent).
-- Sert au repère « N pharmaciens compatibles le {date} » du formulaire
-- de publication (Phase 6.1). Sans ce fichier, l'interface fonctionne :
-- le repère reste simplement masqué.
-- =====================================================================

create table if not exists public.fsa_centroides (
  fsa text primary key,
  lat double precision not null,
  lng double precision not null
);

insert into public.fsa_centroides (fsa, lat, lng) values
('G4W',48.8286,-67.5220),
('G5H',48.5839,-68.1921),
('G5J',48.4638,-67.4313),
('G5L',48.4160,-68.5979),
('G5M',48.4966,-68.4580),
('G5N',48.3668,-68.4659),
('G5R',47.8304,-69.5342),
('G7P',48.5501,-71.3158),
('G8B',48.5548,-71.6730),
('G8C',48.5278,-71.6364),
('G8E',48.6377,-71.6957),
('G8H',48.5168,-72.2324),
('G8J',48.5834,-72.3324),
('G8K',48.6501,-72.4491),
('G8L',48.8763,-72.2120),
('G8M',48.8832,-72.4487),
('G8N',48.3473,-71.6786),
('G0A',47.3507,-71.2020),
('G1A',46.8588,-71.1920),
('G1J',46.8380,-71.2232),
('G1K',46.8140,-71.2194),
('G1L',46.8304,-71.2455),
('G1M',46.8183,-71.2706),
('G1N',46.8035,-71.2639),
('G1P',46.8097,-71.3102),
('G1R',46.8074,-71.2181),
('G1S',46.7933,-71.2453),
('G1T',46.7741,-71.2609),
('G2C',46.8287,-71.3340),
('G2E',46.8083,-71.3605),
('G2J',46.8399,-71.2781),
('G2K',46.8545,-71.3044),
('G3B',46.9833,-71.2906),
('G3C',47.1691,-71.4332),
('G3H',46.7547,-71.6957),
('G3M',46.6804,-71.7239),
('G3N',46.8524,-71.6206),
('G3S',46.8803,-71.5146),
('G3Z',47.4411,-70.4986),
('G4A',47.7184,-70.2276),
('G5A',47.6575,-70.1559),
('G0X',47.9168,-74.6159),
('G9X',47.4334,-72.7824),
('J5V',46.2559,-72.9415),
('J0B',45.1001,-72.0491),
('J1S',45.5668,-71.9991),
('J1T',45.7668,-71.9324),
('J1X',45.2668,-72.1491),
('H1B',45.6320,-73.5075),
('H1G',45.6109,-73.6211),
('H1H',45.5899,-73.6389),
('H2Y',45.5057,-73.5550),
('H2Z',45.5052,-73.5622),
('H3A',45.5040,-73.5747),
('H3B',45.5005,-73.5684),
('H3G',45.4987,-73.5793),
('H3H',45.5009,-73.5877),
('H3X',45.4819,-73.6421),
('H3Y',45.4876,-73.6045),
('H3Z',45.4825,-73.5933),
('H4W',45.4700,-73.6686),
('H4X',45.4529,-73.6492),
('H9J',45.4501,-73.8659),
('H9P',45.4679,-73.7748),
('H9R',45.4487,-73.8167),
('H9W',45.4334,-73.8659),
('J0X',46.3070,-76.7653),
('J8N',45.6501,-75.6660),
('J9B',45.5001,-75.7827),
('J9E',46.3834,-75.9660),
('J0Z',47.8626,-78.8240),
('J9P',48.1002,-77.7828),
('J9T',48.5669,-78.1162),
('J9V',47.3334,-79.4330),
('J9Z',48.8002,-79.1996),
('G0G',53.0413,-68.6884),
('G4S',50.2713,-66.3751),
('G5B',50.0334,-66.8655),
('G8P',49.9168,-74.3659),
('G4X',48.8334,-64.4819),
('G5V',46.9804,-70.5549),
('G5X',46.2179,-70.7787),
('G5Y',46.1326,-70.6375),
('G5Z',46.0642,-70.7118),
('G6A',46.1437,-70.6817),
('G6E',46.4340,-71.0117),
('G6G',46.0937,-71.3054),
('G6V',46.8033,-71.1779),
('G6W',46.7546,-71.2200),
('G6Y',46.8033,-71.1779),
('H7N',45.5501,-73.6992),
('H7R',45.5526,-73.8507),
('J0K',46.7966,-73.8705),
('J5M',45.8501,-73.7659),
('J5T',45.8834,-73.2825),
('J5X',45.8501,-73.4825),
('J5Y',45.7774,-73.4252),
('J5Z',45.7643,-73.5036),
('J6A',45.7395,-73.4588),
('J6V',45.7140,-73.5357),
('J6W',45.7064,-73.6178),
('J6X',45.7275,-73.7062),
('J6Y',45.7000,-73.7520),
('J7K',45.7700,-73.6049),
('J7L',45.7424,-73.6509),
('J0T',46.3002,-74.5855),
('J5K',45.7334,-74.1325),
('J5L',45.7987,-74.0727),
('J7E',45.6442,-73.8448),
('J7P',45.5779,-73.8809),
('J7R',45.5740,-73.9400),
('J7Y',45.8058,-74.0165),
('J7Z',45.7788,-73.9829),
('J8A',45.9334,-74.0159),
('J8B',45.9501,-74.1325),
('J8E',46.1949,-74.6264),
('J8H',45.6501,-74.3325),
('J9L',46.5501,-75.4993),
('J0J',45.1529,-73.1636),
('J0L',45.1956,-73.5695),
('J0S',45.1082,-74.0451),
('J2G',45.4046,-72.7202),
('J2H',45.3938,-72.7005),
('J2J',45.4005,-72.7825),
('J2K',45.2001,-72.7491),
('J2L',45.3168,-72.6491),
('J2M',45.3501,-72.5658),
('J2N',45.2834,-72.9824),
('J2R',45.6567,-72.9237),
('J2S',45.6139,-72.9912),
('J2T',45.5971,-72.9366),
('J2X',45.3090,-73.2190),
('J2Y',45.3114,-73.3556),
('J3A',45.3339,-73.2744),
('J3B',45.2832,-73.2792),
('J3E',45.5834,-73.3325),
('J3G',45.5946,-73.2283),
('J3L',45.4501,-73.2825),
('J3M',45.4334,-73.1659),
('J3X',45.6834,-73.4325),
('J4B',45.5910,-73.4361),
('J4P',45.5073,-73.5082),
('J4R',45.4924,-73.5009),
('J4S',45.4810,-73.4970),
('J4W',45.4674,-73.4832),
('J4X',45.4455,-73.4841),
('J4Y',45.4414,-73.4561),
('J4Z',45.4424,-73.4231),
('J5A',45.3668,-73.5659),
('J5B',45.3668,-73.5492),
('J5C',45.4001,-73.5825),
('J5R',45.4168,-73.4992),
('J6J',45.3691,-73.7216),
('J6K',45.3526,-73.7305),
('J6N',45.3168,-73.8659),
('J6R',45.3168,-73.7492),
('J6S',45.2702,-74.0482),
('J6T',45.2409,-74.1098),
('J7V',45.4001,-74.0325),
('G0P',46.0119,-71.7199),
('G0Z',46.1790,-72.1569),
('G6L',46.2186,-71.7620),
('G6P',46.0529,-71.9477),
('G6T',46.0828,-71.9728),
('J0A',45.8382,-71.9542),
('J0C',45.8567,-72.6966),
('J2A',45.8152,-72.4027),
('J2C',45.8893,-72.5055),
('J2E',45.9099,-72.5289),
('J3T',46.2168,-72.6158),
('G0B',47.4501,-72.9913),
('G0C',48.3429,-65.5961),
('G0E',48.9182,-65.3736),
('G0H',49.3795,-67.8948),
('G0J',48.5246,-67.0565),
('G0K',48.1590,-68.1951),
('G0L',47.7136,-69.1658),
('G0M',45.9718,-70.6565),
('G0N',46.0988,-71.1248),
('G0R',46.7980,-70.3288),
('G0S',46.4526,-71.4397),
('G0T',49.0143,-69.6231),
('G0V',50.1719,-70.6283),
('G0W',49.8340,-72.2623),
('G0Y',45.6242,-71.0191),
('G1B',46.9263,-71.2258),
('G1C',46.8801,-71.1960),
('G1E',46.8588,-71.1920),
('G1G',46.8765,-71.2839),
('G1H',46.8528,-71.2573),
('G1V',46.7823,-71.2882),
('G1W',46.7589,-71.2980),
('G1X',46.7749,-71.3344),
('G1Y',46.7507,-71.3562),
('G2A',46.8751,-71.3920),
('G2B',46.8505,-71.3357),
('G2G',46.7903,-71.4157),
('G2L',46.8895,-71.2545),
('G2M',46.9220,-71.3056),
('G2N',46.9137,-71.3398),
('G3A',46.7406,-71.4513),
('G3E',46.8779,-71.3408),
('G3G',46.9242,-71.3958),
('G3J',46.8603,-71.4752),
('G3K',46.8315,-71.4429),
('G3L',47.2374,-71.8763),
('G4R',50.8558,-67.0511),
('G4T',47.3999,-61.7996),
('G4V',48.9711,-66.3082),
('G4Z',51.0872,-68.6320),
('G5C',50.3474,-69.0411),
('G5T',47.5473,-68.6431),
('G6B',45.5834,-70.8823),
('G6C',46.7701,-71.0906),
('G6H',46.0700,-71.4393),
('G6J',46.6358,-71.3098),
('G6K',46.6880,-71.3028),
('G6R',46.0160,-71.9561),
('G6S',46.0264,-71.8719),
('G6X',46.7151,-71.2612),
('G6Z',46.6901,-71.1849),
('G7A',46.6842,-71.3827),
('G7B',48.3398,-70.8893),
('G7G',48.4450,-71.1025),
('G7H',48.4187,-71.0417),
('G7J',48.4175,-71.1031),
('G7K',48.3689,-71.1175),
('G7N',48.2007,-71.1426),
('G7S',48.4294,-71.1774),
('G7T',48.3975,-71.1527),
('G7X',48.3199,-71.4149),
('G7Y',48.3701,-71.2358),
('G7Z',48.4381,-71.2642),
('G8A',48.4233,-71.3629),
('G8G',47.8076,-71.5907),
('G8T',46.3877,-72.5357),
('G8V',46.4098,-72.4908),
('G8W',46.4176,-72.6372),
('G8Y',46.3668,-72.6168),
('G8Z',46.3458,-72.5716),
('G9A',46.3695,-72.6789),
('G9B',46.3160,-72.6833),
('G9C',46.3922,-72.6725),
('G9H',46.3334,-72.4324),
('G9N',46.5564,-72.7198),
('G9P',46.5068,-72.7436),
('G9R',46.6098,-72.8266),
('G9T',46.6315,-72.7370),
('H0M',45.6986,-73.5025),
('H1A',45.6753,-73.5016),
('H1C',45.6656,-73.5367),
('H1E',45.6342,-73.5842),
('H1J',45.6097,-73.5794),
('H1K',45.6097,-73.5472),
('H1L',45.6043,-73.5178),
('H1M',45.5883,-73.5572),
('H1N',45.5779,-73.5304),
('H1P',45.5966,-73.5928),
('H1R',45.5864,-73.6082),
('H1S',45.5808,-73.5825),
('H1T',45.5730,-73.5701),
('H1V',45.5585,-73.5386),
('H1W',45.5442,-73.5468),
('H1X',45.5583,-73.5701),
('H1Y',45.5486,-73.5788),
('H1Z',45.5694,-73.6221),
('H2A',45.5618,-73.5990),
('H2B',45.5741,-73.6507),
('H2C',45.5606,-73.6584),
('H2E',45.5514,-73.6116),
('H2G',45.5438,-73.5927),
('H2H',45.5374,-73.5735),
('H2J',45.5302,-73.5831),
('H2K',45.5307,-73.5547),
('H2L',45.5186,-73.5545),
('H2M',45.5528,-73.6411),
('H2N',45.5394,-73.6513),
('H2P',45.5435,-73.6339),
('H2R',45.5401,-73.6225),
('H2S',45.5354,-73.6061),
('H2T',45.5247,-73.5953),
('H2V',45.5168,-73.6072),
('H2W',45.5176,-73.5804),
('H2X',45.5115,-73.5683),
('H3C',45.4980,-73.5472),
('H3E',45.4594,-73.5501),
('H3J',45.4861,-73.5732),
('H3K',45.4805,-73.5554),
('H3L',45.5467,-73.6718),
('H3M',45.5383,-73.6932),
('H3N',45.5302,-73.6327),
('H3P',45.5217,-73.6393),
('H3R',45.5101,-73.6478),
('H3S',45.5063,-73.6297),
('H3T',45.5018,-73.6191),
('H3V',45.4990,-73.6089),
('H3W',45.4897,-73.6312),
('H4A',45.4717,-73.6149),
('H4B',45.4604,-73.6303),
('H4C',45.4737,-73.5882),
('H4E',45.4546,-73.5985),
('H4G',45.4643,-73.5698),
('H4H',45.4459,-73.5815),
('H4J',45.5313,-73.7091),
('H4K',45.5171,-73.7363),
('H4L',45.5170,-73.6831),
('H4M',45.4979,-73.6886),
('H4N',45.5263,-73.6649),
('H4P',45.4964,-73.6647),
('H4R',45.5049,-73.7142),
('H4S',45.4858,-73.7433),
('H4T',45.4752,-73.6961),
('H4V',45.4671,-73.6487),
('H4Y',45.8654,-72.7614),
('H4Z',45.5061,-73.5573),
('H5A',45.4992,-73.5646),
('H5B',45.5066,-73.5623),
('H7A',45.6739,-73.5924),
('H7B',45.6757,-73.6388),
('H7C',45.6168,-73.6492),
('H7E',45.6225,-73.6949),
('H7G',45.5771,-73.6873),
('H7H',45.6409,-73.7542),
('H7J',45.6625,-73.7002),
('H7K',45.6213,-73.7398),
('H7L',45.6168,-73.7825),
('H7M',45.5984,-73.7159),
('H7P',45.5780,-73.8004),
('H7S',45.5793,-73.7367),
('H7T',45.5573,-73.7725),
('H7V',45.5478,-73.7368),
('H7W',45.5338,-73.7652),
('H7X',45.5334,-73.8159),
('H7Y',45.5284,-73.8509),
('H8N',45.4380,-73.6215),
('H8P',45.4011,-73.6190),
('H8R',45.3994,-73.6506),
('H8S',45.4402,-73.6747),
('H8T',45.4419,-73.7057),
('H8Y',45.5084,-73.8075),
('H8Z',45.5069,-73.8407),
('H9A',45.4948,-73.8317),
('H9B',45.4897,-73.7958),
('H9C',45.5055,-73.8789),
('H9E',45.4865,-73.9092),
('H9G',45.4756,-73.8367),
('H9H',45.4683,-73.8565),
('H9K',45.4577,-73.9162),
('H9S',45.4414,-73.7749),
('H9X',45.4062,-73.9456),
('J0E',45.2831,-72.5244),
('J0G',46.0210,-72.8239),
('J0H',45.6609,-72.7700),
('J0M',58.3269,-72.1637),
('J0N',45.5135,-74.0534),
('J0P',45.3655,-74.3120),
('J0R',45.8660,-74.1785),
('J0V',45.8265,-74.9318),
('J0W',47.0921,-75.7967),
('J0Y',52.1046,-75.2807),
('J1A',45.1334,-71.7991),
('J1C',45.4797,-71.9492),
('J1E',45.4231,-71.8723),
('J1G',45.4024,-71.8479),
('J1H',45.3891,-71.8986),
('J1J',45.4131,-71.9238),
('J1K',45.3822,-71.9327),
('J1L',45.4113,-71.9586),
('J1M',45.3656,-71.8420),
('J1N',45.3395,-72.0128),
('J1R',45.3966,-72.0422),
('J1Z',45.9334,-72.4324),
('J2B',45.9061,-72.5929),
('J2W',45.3694,-73.3137),
('J3H',45.5527,-73.1755),
('J3N',45.5334,-73.2825),
('J3P',46.0365,-73.0665),
('J3R',46.0206,-73.1439),
('J3V',45.5320,-73.3437),
('J3Y',45.4906,-73.3991),
('J3Z',45.4981,-73.4012),
('J4G',45.5679,-73.4761),
('J4H',45.5372,-73.5056),
('J4J',45.5362,-73.4721),
('J4K',45.5183,-73.5023),
('J4L',45.5181,-73.4576),
('J4M',45.5418,-73.4382),
('J4N',45.5523,-73.4558),
('J4T',45.4973,-73.4676),
('J4V',45.4865,-73.4622),
('J5J',45.8306,-73.9191),
('J5W',45.8232,-73.4294),
('J6E',46.0168,-73.4492),
('J6Z',45.6694,-73.7752),
('J7A',45.6383,-73.7975),
('J7B',45.6602,-73.8157),
('J7C',45.6890,-73.8671),
('J7G',45.6095,-73.8378),
('J7H',45.6209,-73.8728),
('J7J',45.7045,-73.9472),
('J7M',45.7888,-73.7442),
('J7N',45.6345,-74.1005),
('J7T',45.3702,-74.1249),
('J7W',45.3665,-73.9736),
('J7X',45.2691,-74.2339),
('J8C',46.0501,-74.2825),
('J8G',45.6834,-74.4159),
('J8L',45.5856,-75.4208),
('J8M',45.5435,-75.4274),
('J8P',45.4869,-75.6157),
('J8R',45.5287,-75.6088),
('J8T',45.4776,-75.7059),
('J8V',45.5711,-75.7615),
('J8X',45.4400,-75.7119),
('J8Y',45.4480,-75.7434),
('J8Z',45.4716,-75.7616),
('J9A',45.4279,-75.7711),
('J9H',45.3932,-75.8288),
('J9J',45.4394,-75.8465),
('J9X',48.2855,-78.8234),
('J9Y',48.1607,-79.0714)
on conflict (fsa) do update set lat = excluded.lat, lng = excluded.lng;

alter table public.fsa_centroides enable row level security;
drop policy if exists "fsa_lecture" on public.fsa_centroides;
create policy "fsa_lecture" on public.fsa_centroides for select using (auth.role() = 'authenticated');

-- RTA (3 premiers caractères) d'un code postal
create or replace function public.cd_fsa(cp text)
returns text language sql immutable as $$
  select case when cp ~* '^[GHJ][0-9][A-Z]'
    then upper(substring(regexp_replace(cp,'\s','','g') from 1 for 3)) end;
$$;

-- distance haversine (km) entre deux codes postaux, via les centroïdes RTA
create or replace function public.cd_distance_km(cp1 text, cp2 text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare a public.fsa_centroides; b public.fsa_centroides; r constant double precision := 6371;
  dlat double precision; dlng double precision; h double precision;
begin
  select * into a from public.fsa_centroides where fsa = public.cd_fsa(cp1);
  select * into b from public.fsa_centroides where fsa = public.cd_fsa(cp2);
  if a is null or b is null then return null; end if;
  dlat := radians(b.lat - a.lat); dlng := radians(b.lng - a.lng);
  h := sin(dlat/2)^2 + cos(radians(a.lat))*cos(radians(b.lat))*sin(dlng/2)^2;
  return round((2*r*asin(sqrt(h)))::numeric);
end; $$;

-- Comptage des pharmaciens compatibles pour un contrat de cette pharmacie
-- (logique Phase 5 : approuvés, distance <= rayon, tarif min <= tarif offert,
--  logiciel commun, et disponible ce jour-là s'ils tiennent un calendrier).
create or replace function public.compter_compatibles(p_date date, p_tarif numeric)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_pe public.profiles; n integer;
begin
  select * into v_pe from public.profiles where id = auth.uid();
  if v_pe.role not in ('pharmacie','admin') then raise exception 'Accès refusé'; end if;

  select count(*) into n from public.profiles pn
   where pn.role = 'pharmacien' and coalesce(pn.approuve,false) = true
     and (v_pe.code_postal is null or pn.code_postal is null or pn.rayon_deplacement_km is null
          or public.cd_distance_km(pn.code_postal, v_pe.code_postal) <= pn.rayon_deplacement_km)
     and (pn.tarif_horaire_min is null or pn.tarif_horaire_min <= p_tarif)
     and (v_pe.logiciel is null or pn.logiciels is null or v_pe.logiciel = any(pn.logiciels))
     and (
       not exists (select 1 from public.disponibilites d
                    where d.pharmacien_id = pn.id
                      and date_trunc('month', d.date_dispo) = date_trunc('month', p_date))
       or exists (select 1 from public.disponibilites d
                   where d.pharmacien_id = pn.id and d.date_dispo = p_date)
     );
  return n;
end; $$;
revoke all on function public.compter_compatibles(date, numeric) from public, anon;
grant execute on function public.compter_compatibles(date, numeric) to authenticated;

-- ========== 15 : langue + confirmation contrat ==========
-- =====================================================================
-- C-DIRECT · SQL 15 — Préférence de langue + confirmation de contrat
-- À exécuter dans Supabase → SQL Editor (idempotent).
--
-- 1) profiles.langue ('fr' par défaut, 'en' possible) — choisie au profil.
-- 2) À l'acceptation d'une candidature, la confirmation « contrat confirmé »
--    (courriel bilingue + PDF joint) est désormais envoyée par le Worker
--    c-direct-sms (via le webhook candidatures UPDATE). On RETIRE donc la
--    branche 'accepte' de l'ancien trigger courriel pour éviter les doublons.
--    Les courriels contre-offre et refus (manuel) restent inchangés.
--
-- Pré-requis côté Worker : ajouter le secret RESEND_API_KEY (et au besoin
--   RESEND_FROM) puis redéployer :  npx wrangler secret put RESEND_API_KEY
-- =====================================================================

alter table public.profiles
  add column if not exists langue text not null default 'fr'
  check (langue in ('fr','en'));

-- Trigger courriel candidatures : version SANS la branche 'accepte'
create or replace function public.notifier_maj_candidature()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_contrat public.contrats%rowtype;
  v_pharmacien public.profiles%rowtype;
  v_dernier_jalon jsonb;
  v_auto boolean;
begin
  if new.statut = old.statut then return new; end if;

  select * into v_contrat from public.contrats where id = new.contrat_id;
  select * into v_pharmacien from public.profiles where id = new.pharmacien_id;

  begin
    v_dernier_jalon := (new.message::jsonb) -> -1;
  exception when others then
    v_dernier_jalon := null;
  end;
  v_auto := coalesce((v_dernier_jalon ->> 'auto')::boolean, false);

  if new.statut = 'contre_offre' then
    perform public.envoyer_email(
      v_pharmacien.courriel,
      'Contre-offre reçue — ' || v_contrat.numero_reference,
      '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
      '<p>La pharmacie vous a fait une contre-offre sur le contrat <b>' || v_contrat.numero_reference || '</b>.</p>' ||
      '<p>Connectez-vous pour l’accepter ou la refuser.</p>' ||
      '<p>— C-Direct</p>'
    );

  -- 'accepte' : la confirmation (courriel bilingue + PDF) est envoyée par
  -- le Worker c-direct-sms. Aucun courriel ici pour éviter les doublons.

  elsif new.statut = 'refuse' and not v_auto then
    perform public.envoyer_email(
      v_pharmacien.courriel,
      'Candidature non retenue — ' || v_contrat.numero_reference,
      '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
      '<p>Votre candidature pour le contrat <b>' || v_contrat.numero_reference || '</b> n’a pas été retenue.</p>' ||
      '<p>— C-Direct</p>'
    );
  end if;

  return new;
end;
$$;
