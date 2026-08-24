INSERT INTO exercise_catalog (id, name, category, is_custom)
SELECT seed.id, seed.name, seed.category, FALSE
FROM (
    VALUES
        ('00000000-0000-4000-8000-000000000001'::uuid, 'Back Squat', 'strength'),
        ('00000000-0000-4000-8000-000000000002'::uuid, 'Bench Press', 'strength'),
        ('00000000-0000-4000-8000-000000000003'::uuid, 'Deadlift', 'strength'),
        ('00000000-0000-4000-8000-000000000004'::uuid, 'Overhead Press', 'strength'),
        ('00000000-0000-4000-8000-000000000005'::uuid, 'Pull-Up', 'strength'),
        ('00000000-0000-4000-8000-000000000006'::uuid, 'Barbell Row', 'strength'),
        ('00000000-0000-4000-8000-000000000007'::uuid, 'Romanian Deadlift', 'strength'),
        ('00000000-0000-4000-8000-000000000008'::uuid, 'Leg Press', 'strength'),
        ('00000000-0000-4000-8000-000000000009'::uuid, 'Running', 'cardio'),
        ('00000000-0000-4000-8000-00000000000a'::uuid, 'Cycling', 'cardio'),
        ('00000000-0000-4000-8000-00000000000b'::uuid, 'Walking', 'cardio'),
        ('00000000-0000-4000-8000-00000000000c'::uuid, 'Rowing Machine', 'cardio'),
        ('00000000-0000-4000-8000-00000000000d'::uuid, 'Jump Rope', 'cardio'),
        ('00000000-0000-4000-8000-00000000000e'::uuid, 'Elliptical', 'cardio'),
        ('00000000-0000-4000-8000-00000000000f'::uuid, 'Yoga Flow', 'mobility'),
        ('00000000-0000-4000-8000-000000000010'::uuid, 'Dynamic Stretching', 'mobility'),
        ('00000000-0000-4000-8000-000000000011'::uuid, 'Foam Rolling', 'mobility'),
        ('00000000-0000-4000-8000-000000000012'::uuid, 'Mobility Circuit', 'mobility'),
        ('00000000-0000-4000-8000-000000000013'::uuid, 'Swimming', 'sport'),
        ('00000000-0000-4000-8000-000000000014'::uuid, 'Tennis', 'sport'),
        ('00000000-0000-4000-8000-000000000015'::uuid, 'Basketball', 'sport'),
        ('00000000-0000-4000-8000-000000000016'::uuid, 'Football Match', 'sport'),
        ('00000000-0000-4000-8000-000000000017'::uuid, 'Other Exercise', 'other')
) AS seed(id, name, category)
WHERE NOT EXISTS (
    SELECT 1
    FROM exercise_catalog existing
    WHERE lower(existing.name) = lower(seed.name)
      AND existing.is_custom = FALSE
);
