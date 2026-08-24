import Foundation
import GRDB

enum NutritionSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .foodLogs,
        .foodItems,
        .userFoods,
        .userFoodFavorites,
        .mealTemplates,
        .batchRecipes,
        .batchRecipeIngredients,
        .dailyNutritionTargets,
        .foodCatalogItems
    ]

    static let pullTables: [SyncableTable] = [
        .foodLogs,
        .foodItems,
        .userFoods,
        .userFoodFavorites,
        .mealTemplates,
        .batchRecipes,
        .batchRecipeIngredients
    ]

    static func reconcileParentChild(in db: Database) throws {
        // food_logs <- food_items
        try db.execute(sql: """
            UPDATE food_logs
            SET calories = COALESCE((
                    SELECT SUM(fi.calories)
                    FROM food_items fi
                    WHERE fi.food_log_id = food_logs.id
                ), 0),
                protein_g = COALESCE((
                    SELECT SUM(fi.protein_g)
                    FROM food_items fi
                    WHERE fi.food_log_id = food_logs.id
                ), 0),
                fat_g = COALESCE((
                    SELECT SUM(fi.fat_g)
                    FROM food_items fi
                    WHERE fi.food_log_id = food_logs.id
                ), 0),
                carbs_g = COALESCE((
                    SELECT SUM(fi.carbs_g)
                    FROM food_items fi
                    WHERE fi.food_log_id = food_logs.id
                ), 0)
            WHERE EXISTS (
                SELECT 1
                FROM food_items fi
                JOIN sync_row_state child_sync
                  ON child_sync.table_name = 'food_items'
                 AND child_sync.row_id = fi.id
                LEFT JOIN sync_row_state parent_sync
                  ON parent_sync.table_name = 'food_logs'
                 AND parent_sync.row_id = food_logs.id
                WHERE fi.food_log_id = food_logs.id
                  AND (
                    parent_sync.updated_at_server IS NULL OR
                    child_sync.updated_at_server > parent_sync.updated_at_server
                  )
            )
            """)

        // batch_recipes <- batch_recipe_ingredients
        try db.execute(sql: """
            UPDATE batch_recipes
            SET total_calories = COALESCE((
                    SELECT SUM(bri.calories)
                    FROM batch_recipe_ingredients bri
                    WHERE bri.batch_recipe_id = batch_recipes.id
                ), 0),
                total_protein_g = COALESCE((
                    SELECT SUM(bri.protein_g)
                    FROM batch_recipe_ingredients bri
                    WHERE bri.batch_recipe_id = batch_recipes.id
                ), 0),
                total_fat_g = COALESCE((
                    SELECT SUM(bri.fat_g)
                    FROM batch_recipe_ingredients bri
                    WHERE bri.batch_recipe_id = batch_recipes.id
                ), 0),
                total_carbs_g = COALESCE((
                    SELECT SUM(bri.carbs_g)
                    FROM batch_recipe_ingredients bri
                    WHERE bri.batch_recipe_id = batch_recipes.id
                ), 0),
                total_fiber_g = (
                    SELECT SUM(bri.fiber_g)
                    FROM batch_recipe_ingredients bri
                    WHERE bri.batch_recipe_id = batch_recipes.id
                ),
                calories_per_100g = CASE
                    WHEN batch_recipes.total_weight_g > 0
                    THEN COALESCE((
                        SELECT SUM(bri.calories)
                        FROM batch_recipe_ingredients bri
                        WHERE bri.batch_recipe_id = batch_recipes.id
                    ), 0) * 100.0 / batch_recipes.total_weight_g
                END,
                protein_per_100g = CASE
                    WHEN batch_recipes.total_weight_g > 0
                    THEN COALESCE((
                        SELECT SUM(bri.protein_g)
                        FROM batch_recipe_ingredients bri
                        WHERE bri.batch_recipe_id = batch_recipes.id
                    ), 0) * 100.0 / batch_recipes.total_weight_g
                END,
                fat_per_100g = CASE
                    WHEN batch_recipes.total_weight_g > 0
                    THEN COALESCE((
                        SELECT SUM(bri.fat_g)
                        FROM batch_recipe_ingredients bri
                        WHERE bri.batch_recipe_id = batch_recipes.id
                    ), 0) * 100.0 / batch_recipes.total_weight_g
                END,
                carbs_per_100g = CASE
                    WHEN batch_recipes.total_weight_g > 0
                    THEN COALESCE((
                        SELECT SUM(bri.carbs_g)
                        FROM batch_recipe_ingredients bri
                        WHERE bri.batch_recipe_id = batch_recipes.id
                    ), 0) * 100.0 / batch_recipes.total_weight_g
                END,
                weight_per_portion_g = CASE
                    WHEN batch_recipes.total_portions IS NOT NULL
                     AND batch_recipes.total_portions > 0
                     AND batch_recipes.total_weight_g > 0
                    THEN batch_recipes.total_weight_g * 1.0 / batch_recipes.total_portions
                END
            WHERE EXISTS (
                SELECT 1
                FROM batch_recipe_ingredients bri
                JOIN sync_row_state child_sync
                  ON child_sync.table_name = 'batch_recipe_ingredients'
                 AND child_sync.row_id = bri.id
                LEFT JOIN sync_row_state parent_sync
                  ON parent_sync.table_name = 'batch_recipes'
                 AND parent_sync.row_id = batch_recipes.id
                WHERE bri.batch_recipe_id = batch_recipes.id
                  AND (
                    parent_sync.updated_at_server IS NULL OR
                    child_sync.updated_at_server > parent_sync.updated_at_server
                  )
            )
            """)
    }
}
