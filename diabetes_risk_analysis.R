# ───────────────────────────────────────────────────────────────
# 1. Install missing packages (run once, or when errors occur)
# ───────────────────────────────────────────────────────────────
if (!require("tidyverse")) install.packages("tidyverse")
if (!require("DBI")) install.packages("DBI")
if (!require("RSQLite")) install.packages("RSQLite")
if (!require("caret")) install.packages("caret")
if (!require("openxlsx")) install.packages("openxlsx")
if (!require("pROC")) install.packages("pROC")

# ───────────────────────────────────────────────────────────────
# 2. Load all libraries
# ───────────────────────────────────────────────────────────────
library(tidyverse)     
library(RSQLite)
library(caret)
library(openxlsx)
library(pROC)

# ───────────────────────────────────────────────────────────────
# 3. Load data
# ───────────────────────────────────────────────────────────────
file_path <- "C:/Users/DELL/Downloads/Viz/diabetes.csv"

if (!file.exists(file_path)) {
  stop("CSV file not found. Check path: ", file_path)
}

diabetic_data <- read_csv(file_path)

# Quick checks
dim(diabetic_data)              # Should be 768 × 9
head(diabetic_data)
summary(diabetic_data)
table(diabetic_data$Outcome)    # 500 / 268

# ───────────────────────────────────────────────────────────────
# 4. Clean & impute 
# ───────────────────────────────────────────────────────────────
diabetic_data_clean <- diabetic_data %>%
  mutate(
    Glucose       = na_if(Glucose, 0),
    BloodPressure = na_if(BloodPressure, 0),
    SkinThickness = na_if(SkinThickness, 0),
    Insulin       = na_if(Insulin, 0),
    BMI           = na_if(BMI, 0)
  ) %>%
  group_by(Outcome) %>%
  mutate(
    Glucose       = coalesce(Glucose,       median(Glucose, na.rm = TRUE)),
    BloodPressure = coalesce(BloodPressure, median(BloodPressure, na.rm = TRUE)),
    SkinThickness = coalesce(SkinThickness, median(SkinThickness, na.rm = TRUE)),
    Insulin       = coalesce(Insulin,       median(Insulin, na.rm = TRUE)),
    BMI           = coalesce(BMI,           median(BMI, na.rm = TRUE))
  ) %>%
  ungroup()

# Verify cleaning
summary(diabetic_data_clean)
colSums(is.na(diabetic_data_clean))  # Should all be 0

# ───────────────────────────────────────────────────────────────
# 5. Write to SQLite (use consistent table name)
# ───────────────────────────────────────────────────────────────
con <- dbConnect(RSQLite::SQLite(), "healthcare_db.sqlite")


dbWriteTable(con, "patients", diabetic_data_clean, overwrite = TRUE)


dbListTables(con)               # Should show "patients"
dbGetQuery(con, "SELECT * FROM patients LIMIT 5")

# ───────────────────────────────────────────────────────────────
# 6. Extract via SQL 
# ───────────────────────────────────────────────────────────────
sql_query_full <- "
SELECT 
  Pregnancies,
  CASE WHEN Glucose = 0 THEN NULL ELSE Glucose END AS Glucose,
  CASE WHEN BloodPressure = 0 THEN NULL ELSE BloodPressure END AS BloodPressure,
  CASE WHEN SkinThickness = 0 THEN NULL ELSE SkinThickness END AS SkinThickness,
  CASE WHEN Insulin = 0 THEN NULL ELSE Insulin END AS Insulin,
  CASE WHEN BMI = 0 THEN NULL ELSE BMI END AS BMI,
  DiabetesPedigreeFunction,
  Age,
  Outcome
FROM patients
"

extracted <- dbGetQuery(con, sql_query_full)

head(extracted)
summary(extracted)

dbDisconnect(con)

# ───────────────────────────────────────────────────────────────
# 7. Final analysis dataset
# ───────────────────────────────────────────────────────────────
data_for_analysis <- extracted %>%
  mutate(
    Glucose       = coalesce(Glucose,       median(Glucose, na.rm = TRUE)),
    BloodPressure = coalesce(BloodPressure, median(BloodPressure, na.rm = TRUE)),
    SkinThickness = coalesce(SkinThickness, median(SkinThickness, na.rm = TRUE)),
    Insulin       = coalesce(Insulin,       median(Insulin, na.rm = TRUE)),
    BMI           = coalesce(BMI,           median(BMI, na.rm = TRUE))
  )

summary(data_for_analysis)
colSums(is.na(data_for_analysis))  # Should be 0

# ───────────────────────────────────────────────────────────────
# 8. EDA summaries
# ───────────────────────────────────────────────────────────────
data_for_analysis %>%
  group_by(Outcome) %>%
  summarise(
    n = n(),
    avg_glucose = mean(Glucose),
    avg_bmi = mean(BMI),
    avg_age = mean(Age),
    avg_insulin = mean(Insulin),
    avg_pregnancies = mean(Pregnancies)
  )

prop.table(table(data_for_analysis$Outcome)) * 100

# ───────────────────────────────────────────────────────────────
# 9. Visualizations
# ───────────────────────────────────────────────────────────────
ggplot(data_for_analysis, aes(x = Glucose, y = BMI, color = factor(Outcome))) +
  geom_point(alpha = 0.6, size = 2) +
  labs(title = "Glucose vs BMI by Diabetes Outcome",
       subtitle = "1 = Diabetes, 0 = No Diabetes",
       x = "Plasma Glucose (mg/dL)", y = "Body Mass Index",
       color = "Outcome") +
  theme_minimal()

ggsave("glucose_bmi_by_outcome.png", width = 8, height = 6)

ggplot(data_for_analysis, aes(x = factor(Outcome), y = Insulin)) +
  geom_boxplot(fill = "lightblue") +
  labs(title = "Insulin Levels by Diabetes Status", x = "Outcome", y = "Insulin") +
  theme_minimal()

ggsave("insulin_by_outcome.png")

# ───────────────────────────────────────────────────────────────
# 10. Logistic Regression Model
# ───────────────────────────────────────────────────────────────
set.seed(123)

trainIndex <- createDataPartition(data_for_analysis$Outcome, p = 0.7, list = FALSE)
train_data <- data_for_analysis[trainIndex, ]
test_data  <- data_for_analysis[-trainIndex, ]

model_lr <- glm(Outcome ~ Glucose + BMI + Age + Pregnancies + Insulin + DiabetesPedigreeFunction,
                data = train_data, family = binomial)

summary(model_lr)

pred_prob <- predict(model_lr, test_data, type = "response")
pred_class <- ifelse(pred_prob > 0.5, 1, 0)

confusionMatrix(factor(pred_class), factor(test_data$Outcome))

# ───────────────────────────────────────────────────────────────
# 11. Export Excel Report
# ───────────────────────────────────────────────────────────────
wb <- createWorkbook()

# Sheet 1: Cleaned Data
addWorksheet(wb, "Cleaned_Data")
writeData(wb, "Cleaned_Data", data_for_analysis)

# Sheet 2: Summary Stats
summary_by_outcome <- data_for_analysis %>%
  group_by(Outcome) %>%
  summarise(across(c(Glucose, BMI, Age, Insulin, Pregnancies), mean, na.rm = TRUE), n = n())

addWorksheet(wb, "Summary_Stats")
writeData(wb, "Summary_Stats", summary_by_outcome)

# Sheet 3: Model Coefficients
model_summary_df <- as.data.frame(summary(model_lr)$coefficients)
model_summary_df$Predictor <- rownames(model_summary_df)
addWorksheet(wb, "Model_Summary")
writeData(wb, "Model_Summary", model_summary_df)

# Sheet 4: Odds Ratios
odds_ratios <- exp(coef(model_lr))
ci <- exp(confint(model_lr))
odds_df <- data.frame(
  Predictor     = names(odds_ratios),
  Odds_Ratio    = round(odds_ratios, 3),
  CI_Lower_2.5  = round(ci[,1], 3),
  CI_Upper_97.5 = round(ci[,2], 3)
)
addWorksheet(wb, "Odds_Ratios")
writeData(wb, "Odds_Ratios", odds_df)

# Sheet 5: Confusion Matrix
cm <- confusionMatrix(factor(pred_class), factor(test_data$Outcome))
cm_table <- as.data.frame(cm$table)
cm_stats <- data.frame(
  Metric = c("Accuracy", "Sensitivity", "Specificity", "Kappa"),
  Value  = c(round(cm$overall["Accuracy"], 4),
             round(cm$byClass["Sensitivity"], 4),
             round(cm$byClass["Specificity"], 4),
             round(cm$overall["Kappa"], 4))
)
addWorksheet(wb, "Confusion_Matrix")
writeData(wb, "Confusion_Matrix", cm_table, startRow = 1)
writeData(wb, "Confusion_Matrix", cm_stats, startRow = nrow(cm_table) + 4)

# Sheet 6: Overview
addWorksheet(wb, "Overview")
writeData(wb, "Overview", data.frame(
  Note = c(
    "Diabetes Risk Analysis Report",
    paste("Generated:", Sys.time()),
    "Dataset: Pima Indians Diabetes (768 obs)",
    "Model: Logistic Regression",
    paste("Test Accuracy:", round(cm$overall["Accuracy"], 4))
  )
))

saveWorkbook(wb, "diabetes_risk_report.xlsx", overwrite = TRUE)
cat("Excel report saved: diabetes_risk_report.xlsx\n")

