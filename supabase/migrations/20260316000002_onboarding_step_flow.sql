ALTER TABLE onboarding_state
    DROP CONSTRAINT IF EXISTS onboarding_state_step_check;

ALTER TABLE onboarding_state
    ADD CONSTRAINT onboarding_state_step_check
    CHECK (
        step IN (
            'not_started',
            'auth_complete',
            'profile_complete',
            'healthkit_prompted',
            'healthkit_granted',
            'healthkit_skipped',
            'backfill_in_progress',
            'backfill_complete',
            'tutorial_shown',
            'value_prop_complete',
            'quick_win_complete',
            'first_insight_delivered',
            'notifications_prompted',
            'onboarding_complete'
        )
    );
