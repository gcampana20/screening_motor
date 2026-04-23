INSERT INTO public.list (
    id,
    created_at,
    name,
    type,
    description
)
VALUES (
    uuid_generate_v4(),
    now(),
    'OFAC SDN',
    'SANCTIONS',
    'OFAC sanctions list'
)
RETURNING id;