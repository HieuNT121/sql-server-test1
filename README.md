# SQL Ultimate Course

Welcome to the **SQL Ultimate Course** repository! 🚀  
This course will cover everything you need to master SQL!

## Run SQL Server 2022 and the dashboard

This repository includes a Docker Compose environment with:

- SQL Server 2022 Developer Edition
- automatic, one-time initialization of `SalesDB` and `MyDatabase`
- repeatable SalesDB enrichment with multi-year sample orders and analytics tables
- a browser dashboard that reads live data from `SalesDB`

Start everything:

```bash
docker compose up --build
```

Then open [http://localhost:3000](http://localhost:3000). SQL Server is also
available to database tools at `localhost,14331` with user `sa`. The default
development password is `SqlServer2022!Demo`; copy `.env.example` to `.env` and
change `MSSQL_SA_PASSWORD` before using the setup outside a local demo.

Useful commands:

```bash
# Run in the background
docker compose up --build -d

# View service status and logs
docker compose ps
docker compose logs -f

# Stop containers without deleting database data
docker compose down

# Stop containers and delete the local SQL Server volume
docker compose down -v
```

The initializer does not overwrite databases that already exist in the Docker
volume. It applies the additive `datasets/sql-server/enrich-salesdb.sql` script
on startup; that script creates the extended schema and sample records once and
leaves existing rows intact. The advanced query pack is
`scripts/28_Advanced_Sales_Analytics.sql`.

The enrichment adds a normalized product catalog, customer profiles, order
lines, payments, returns, and inventory snapshots. It expands SalesDB to 40
customers and 250 current orders. Run the advanced query pack in SQL Server
Management Studio or with `sqlcmd` to explore monthly trends, RFM customer
segments, product contribution, cohort retention, return rates, inventory
signals, reconciliations, and a parameterized stored procedure.

## Daily sales business pipeline

Docker also provisions a metadata-driven, five-layer in-database pipeline:

1. **Quality gate:** validate customer, product, date, line, and payment data.
2. **Reference extraction:** map every order to a store location from country rules.
3. **Daily operations:** aggregate overall and per-store sales and refresh customer value.
4. **Business metrics:** calculate ranked product performance and margins.
5. **Publication:** publish a one-row executive KPI snapshot including the top store.

Each stored procedure has its own file under `datasets/sql-server/pipeline/`.
`Pipeline.usp_RunSalesAnalyticsPipeline` reads the registered step definitions.
`Pipeline.usp_ExecutePipelineStep` checks dependencies and uses explicit `EXEC`
statements to call each already-existing procedure, including
`Pipeline.usp_ExtractStoreLocationMapping`. It records status, duration, rows,
and errors. An application lock prevents
overlapping runs. Select **Run pipeline** on the dashboard to launch a run and
inspect its dependency graph, step logs, and quality-gate results. Audit data is
stored in `Pipeline.PipelineRuns`, `Pipeline.PipelineStepRuns`, and
`Pipeline.DataQualityResults`.

## Advanced conversion fixtures

The initialization manifest applies
`datasets/sql-server/pipeline/03-advanced-salesdb.sql`, which adds the advanced
SalesDB objects and source data used to test T-SQL-to-Spark conversions. It then
deploys every block in `datasets/sql-server/pipeline/04-conversion-challenges.sql`
as its own `Sales.usp_ConversionChallenge_C01` through
`Sales.usp_ConversionChallenge_C30` stored procedure. The fixtures
deliberately include dirty records, so they are kept separate from the daily
analytics pipeline's quality gate.

The dashboard pipeline selector also includes **T-SQL conversion readiness
pipeline**. It validates the advanced fixture set, runs all 30 challenge
procedures as separate logged steps, publishes their results, and records the
latest 32-step run. It verifies
that SQL Server source data is ready for comparison; run the matching blocks in
your converted Databricks notebook to perform the cross-platform result diff.


---

## 🛠️ Important Links & Tools:

Everything is for Free!
- **[Datasets](datasets/):** Access to the course dataset (csv files).
- **[SQL Server Express](https://www.microsoft.com/en-us/sql-server/sql-server-downloads):** Lightweight server for hosting your SQL database.
- **[SQL Server Management Studio (SSMS)](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms?view=sql-server-ver16):** GUI for managing and interacting with databases.

---

## 📂 Repository Structure
```
sql-ultimate-course/
│
├── datasets/                           # Raw datasets used for the course (ERP and CRM data)
│
├── docs/                               # course documentation and architecture details
│
└── scripts/                            # All codes presented in the course
```

---

## ☕ Stay Connected

Let's stay in touch! Feel free to connect with me on the following platforms:

[![YouTube](https://img.shields.io/badge/YouTube-red?style=for-the-badge&logo=youtube&logoColor=white)](http://bit.ly/3GiCVUE)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://linkedin.com/in/baraa-khatib-salkini)
[![Website](https://img.shields.io/badge/Website-000000?style=for-the-badge&logo=google-chrome&logoColor=white)](https://www.datawithbaraa.com)
[![Newsletter](https://img.shields.io/badge/Newsletter-FF5722?style=for-the-badge&logo=substack&logoColor=white)](https://bit.ly/BaraaNewsletter)
[![PayPal](https://img.shields.io/badge/PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/baraasalkini)
[![Join](https://img.shields.io/badge/Join-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@datawithbaraa)

All Courses and their materials are completely free, and all I ask is your support through subscribing, liking, and commenting on my channel. Your engagement means the world to me and It help the channel!
- ✅ **SQL Full Course:** [Course Link](https://youtu.be/SSKVgrwhzus) | [Download Materials](https://www.datawithbaraa.com/sql-introduction/sql-ultimate-course/) | [GIT Repo](https://github.com/DataWithBaraa/sql-ultimate-course)
- ✅ **Tableau Full Course:** [Course Link](https://www.youtube.com/watch?v=K3pXnbniUcM) | [Download Materials](https://www.datawithbaraa.com/tableau/tableau-thank-you/) | [Public](https://public.tableau.com/app/profile/baraa.salkini/vizzes)

- ✅ **SQL Data Warehouse Project:** [Course Link](https://youtu.be/SSKVgrwhzus) | [Download Materials](https://www.datawithbaraa.com/sql-introduction/advanced-sql-project/) | [GIT Repo](https://github.com/DataWithBaraa/sql-data-warehouse-project)
- ✅ **SQL Exploratory Data Analysis Project:** [Course Link](https://youtu.be/SSKVgrwhzus) | [Download Materials](https://www.datawithbaraa.com/sql-introduction/advanced-sql-analytics-project/) | [GIT Repo](https://github.com/DataWithBaraa/sql-data-analytics-project)
- ✅ **SQL Advanced Data Analysis Project:** [Course Link](https://youtu.be/SSKVgrwhzus) | [Download Materials](https://www.datawithbaraa.com/sql-introduction/advanced-sql-analytics-project/) | [GIT Repo](https://github.com/DataWithBaraa/sql-data-analytics-project)
  
- ✅ **Tableau Sales Project:** [Course Link](https://www.youtube.com/watch?v=dahrmqT5GD4) | [Download Materials](https://datawithbaraa.substack.com/p/access-to-course-materials) | [Public](https://public.tableau.com/app/profile/baraa.salkini/vizzes)
- ✅ **Tableau HR Project:** [Course Link](https://www.youtube.com/watch?v=UcGF09Awm4Y) | [Download Materials](https://datawithbaraa.substack.com/p/access-to-course-materials) | [Public](https://public.tableau.com/app/profile/baraa.salkini/vizzes)
- ✅ **ChatGPT:** [Course Link](https://www.youtube.com/watch?v=LJLNfei4i-c) | [Download Materials](https://datawithbaraa.substack.com/p/access-to-course-materials)

---

## 🛡️ License

This course is licensed under the [MIT License](LICENSE). You are free to use, modify, and share this project with proper attribution.

## 🌟 About Me

Hi there! I'm **Baraa Khatib Salkini**, also known as **Data With Baraa**. I’m an IT professional and passionate YouTuber on a mission to share knowledge and make working with data enjoyable and engaging!

Let's stay in touch! Feel free to connect with me on the following platforms:

[![YouTube](https://img.shields.io/badge/YouTube-red?style=for-the-badge&logo=youtube&logoColor=white)](http://bit.ly/3GiCVUE)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://linkedin.com/in/baraa-khatib-salkini)
[![Website](https://img.shields.io/badge/Website-000000?style=for-the-badge&logo=google-chrome&logoColor=white)](https://www.datawithbaraa.com)
[![Newsletter](https://img.shields.io/badge/Newsletter-FF5722?style=for-the-badge&logo=substack&logoColor=white)](https://bit.ly/BaraaNewsletter)
[![PayPal](https://img.shields.io/badge/PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/baraasalkini)
[![Join](https://img.shields.io/badge/Join-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@datawithbaraa)
