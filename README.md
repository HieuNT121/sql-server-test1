# SQL Ultimate Course

Welcome to the **SQL Ultimate Course** repository! 🚀  
This course will cover everything you need to master SQL!

## Run SQL Server 2022 and the dashboard

This repository includes a Docker Compose environment with:

- SQL Server 2022 Developer Edition
- automatic, one-time initialization of `SalesDB` and `MyDatabase`
- a browser dashboard that reads live data from `SalesDB`

Start everything:

```bash
docker compose up --build
```

Then open [http://localhost:3000](http://localhost:3000). SQL Server is also
available to database tools at `localhost,1433` with user `sa`. The default
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
volume. To rebuild the course data from the SQL seed files, use the final command
above and start the stack again.


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
