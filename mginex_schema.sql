CREATE TABLE customers (
    customer_id NUMBER(*,0) NOT NULL,
    email_address VARCHAR2(255 CHAR) NOT NULL,
    full_name VARCHAR2(255 CHAR) NOT NULL,
    CONSTRAINT customers_pk PRIMARY KEY(customer_id),
    CONSTRAINT customers_email_u UNIQUE(email_address)
    );
CREATE INDEX customers_name_i 
ON customers(full_name);

CREATE TABLE stores (
    store_id NUMBER(*,0) NOT NULL,
    store_name VARCHAR2(255 CHAR) NOT NULL,
    web_address VARCHAR2(100 CHAR),
    physical_address VARCHAR2(512 CHAR),
    latitude NUMBER,
    longitude NUMBER,
    logo BLOB,
    logo_mime_type VARCHAR2(512 CHAR),
    logo_filename VARCHAR2(512 CHAR),
    logo_charset VARCHAR2(512 CHAR),
    logo_last_updated DATE,
    CONSTRAINT stores_pk PRIMARY KEY(store_id),
    CONSTRAINT store_name_u UNIQUE (store_name)
    );
    
CREATE TABLE orders (
    order_id NUMBER(*,0) NOT NULL,
    order_datetime TIMESTAMP NOT NULL,
    customer_id NUMBER(*,0) NOT NULL,
    order_status VARCHAR2(10 CHAR) NOT NULL,
    store_id NUMBER(*,0) NOT NULL,
    CONSTRAINT orders_pk PRIMARY KEY(order_id),
    CONSTRAINT orders_store_id_fk FOREIGN KEY(store_id)
        REFERENCES stores(store_id),
    CONSTRAINT orders_customer_id_fk FOREIGN KEY(customer_id)
        REFERENCES customers(customer_id)
    );
CREATE INDEX orders_customer_id_i
ON orders(customer_id);
CREATE INDEX orders_store_id_i
ON orders(store_id);

CREATE TABLE products (
    product_id NUMBER(8,0) NOT NULL,
    product_name VARCHAR2(255 CHAR) NOT NULL,
    unit_price NUMBER(10,2),
    product_details BLOB,
    product_image BLOB,
    image_mime_type VARCHAR2(512 CHAR),
    image_filename VARCHAR2(512 CHAR),
    image_charset VARCHAR2(512 CHAR),
    image_last_updated DATE,
    CONSTRAINT products_pk PRIMARY KEY(product_id)
    );

CREATE TABLE order_items (
    order_id NUMBER(*,0) NOT NULL,
    line_item_id NUMBER(*,0) NOT NULL,
    product_id NUMBER(*,0) NOT NULL,
    unit_price NUMBER(10,2) NOT NULL,
    quantity NUMBER(*,0) NOT NULL,
    CONSTRAINT order_items_pk PRIMARY KEY(order_id, line_item_id),
    CONSTRAINT order_items_product_u UNIQUE(product_id, order_id),
    CONSTRAINT order_items_order_id_fk FOREIGN KEY(order_id)
        REFERENCES orders(order_id),
    CONSTRAINT order_items_product_id_fk FOREIGN KEY(product_id)
        REFERENCES products(product_id)
    );
    
    
    
/*
Split the Full_Name column into First_Name and Last_Name, 
create update query to adjust the data, remove Full_Name column.
*/

ALTER TABLE customers
ADD first_name VARCHAR2(255 CHAR);
ALTER TABLE customers
ADD last_name VARCHAR2(255 CHAR);

UPDATE customers 
SET first_name = regexp_substr( customers.full_name, '[[:alpha:]]+', 1, 1);

UPDATE customers
SET last_name = CASE
    WHEN regexp_count(full_name, '[^ ]+') = 2 THEN regexp_substr( customers.full_name, '[[:alpha:]]+', 1, 2)
    WHEN regexp_count(full_name, '[^ ]+') = 3 THEN regexp_substr( customers.full_name, '[[:alpha:]]+', 1, 3)
END;

ALTER TABLE customers
DROP COLUMN full_name;
            
/*Product_Name is breaking 1NF.  It has the color with the product_name.  
This needs to be fixed!  Create a new table, ProductColor, normalize the data 
so the Product_Name doesn’t have the color, and there’s a new column ProductColorID
*/

CREATE TABLE ProductColor (
    ProductColorID VARCHAR2(255 CHAR) NOT NULL,
    productcolorname VARCHAR2(255 CHAR),
    CONSTRAINT product_color_pk PRIMARY KEY(ProductColorID)
    );

INSERT INTO productcolor(productcolorid)
    select product_name
    from products;
    
UPDATE productcolor 
SET productcolorname = regexp_substr(productcolor.productcolorid, '[[:alpha:]]+', 1, 4);
    
INSERT INTO productcolor(productcolorid)
    (select productcolorname
        from productcolor
        group by productcolorname
        having count(*)>1
    );
    
DELETE FROM productcolor
where (regexp_count(productcolorid, '[^ ]+')!= 1);

ALTER TABLE productcolor
DROP COLUMN productcolorname;

UPDATE products
SET product_name = SUBSTR(product_name, 1, length(product_name)-(length(regexp_substr(product_name, '[[:alpha:]]+', 1, 4))+3));

commit;

/* Unit_Price needs to be fixed!  Each product only has one price?  There should be a new table, 
ProductPrice, that has Product_ID, Effective_Date and Unit_Price.  The product’s price is now a 
calculation based on a given date, using a join between Product and Product_Price.
*/

DROP TABLE productprice; 


CREATE TABLE Products_Price (
    product_id NUMBER(8,0) NOT NULL,
    effective_date DATE NOT NULL,
    unit_price NUMBER(10, 2) NOT NULL,
    CONSTRAINT productprice_pk PRIMARY KEY(product_id, effective_date),
    CONSTRAINT produceprice_fk FOREIGN KEY (product_id)
        REFERENCES products(product_id)
    );

commit;

INSERT INTO products_price(product_id, effective_date, unit_price)
    select product_id, sysdate - 365, unit_price
    from products;

ALTER TABLE products
DROP COLUMN unit_price;

/* Create a view v_product_price(date) that will show the product 
and price as of a given date.  Only one row should be return for 
each product (the current product’s price row)
On piazza said create a query that joins products & products_price 
and uses the eff_date to pull the right product price.  Test this 
by adding a few products_price rows to a product...  different 
eff_date and different unit prices... as a function that passes
in product_id and effective_date and returns unit_price*/

CREATE OR REPLACE FUNCTION FUN_V_PRODUCT_PRICE 
(
  IN_DATE IN DATE,
  IN_PROD_ID IN products.product_id%type
) RETURN products_price.unit_price%type AS 
    u_price_return products_price.unit_price%type;
    
BEGIN

    select p.unit_price
    into u_price_return
    from products_price p
    inner join products pr 
    on (p.product_id = pr.product_id)
    where p.effective_date >= TRUNC(in_date)
    and p.product_id = in_prod_id;
    return u_price_return;
    
END FUN_V_PRODUCT_PRICE;

/* 3.	Create a new procedure, PRC_INCREASE_PRICE(ProductID, Effective_Date, Percent_Increase). 
The end result of this procedure is to create a new row(s) in ProductPrice.
a.	If ProductID is null, increase all products
b.	If EffectiveDate is null, use the maximum date by Product and add one day.
c.	Percent_Increase…  find the prior price (by ProductID and EffectiveDate) and increase 
    (or decrease if negative) the Unit_Price.
*/

create or replace procedure prc_increase_price (
    in_prod_id products.product_id%type, 
    in_e_date products_price.effective_date%type,
    in_percent_incr NUMBER)
as 
    both_values_null EXCEPTION;
BEGIN

    if (in_prod_id is null and in_e_date is not null) then
        INSERT into products_price (product_id, unit_price, effective_date) 
           select p.product_id, p.unit_price*(.01*in_percent_incr+1), sysdate
            from products_price p, (select product_id, max(effective_date) max_date from products_price group by product_id) q
            where (p.product_id = q.product_id) and (p.effective_date = q.max_date);
    end if;
    if (in_e_date is null and in_prod_id is not null) then
         INSERT into products_price (product_id, unit_price, effective_date)
            select p.product_id, p.unit_price*(.01*in_percent_incr+1), q.max_date + 1
            from products_price p, (select product_id, max(effective_date) max_date from products_price group by product_id) q
            where(p.product_id = q.product_id) and (p.effective_date = q.max_date) and p.product_id = in_prod_id;
    end if;
    
    if (in_e_date is null and in_prod_id is null) then 
        raise both_values_null;
    end if;
    
    if (in_e_date is not null and in_prod_id is not null) then
         INSERT into products_price (product_id, unit_price, effective_date)
            select p.product_id, p.unit_price*(.01*in_percent_incr+1), in_e_date
            from products_price p, (select product_id, max(effective_date) max_date from products_price group by product_id) q
            where (p.product_id = q.product_id) and (p.effective_date = q.max_date) and p.product_id = in_prod_id;
    end if;
        
commit;
END;


/* 4.	Create a sequence for Customers, Orders, Products, Stores.  
Enforce the PK values for each table using the sequence via trigger. */

create sequence seq_customers
    start with 393
    increment by 1;

create sequence seq_orders 
    start with 1950
    increment by 1;
    
create sequence seq_products
    start with 46
    increment by 1;
    
create sequence seq_stores
    start with 23
    increment by 1;

create trigger trg_seq_customers  
BEFORE INSERT on customers 
FOR EACH ROW 
BEGIN 
    :new.customer_id := seq_customers.nextval;
END; 

create trigger trg_seq_orders  
BEFORE INSERT on orders 
FOR EACH ROW 
BEGIN 
    :new.order_id := seq_orders.nextval;
END; 

create trigger trg_seq_products  
BEFORE INSERT on products 
FOR EACH ROW 
BEGIN 
    :new.product_id := seq_products.nextval;
END; 

create trigger trg_seq_stores  
BEFORE INSERT on stores 
FOR EACH ROW 
BEGIN 
    :new.store_id := seq_stores.nextval;
END; 


/*5.	Add the CreatedBy, ModifiedBy columns, add the appropriate triggers to value these columns. */

ALTER TABLE customers
ADD (created_by varchar2(20), 
    modified_by varchar2(20));
    
ALTER TABLE order_items
ADD (created_by varchar2(20), 
    modified_by varchar2(20));
    
ALTER TABLE orders
ADD (created_by varchar2(20), 
    modified_by varchar2(20));
    
ALTER TABLE productcolor
ADD (created_by varchar2(20), 
    modified_by varchar2(20));  
    
ALTER TABLE products
ADD (created_by varchar2(20), 
    modified_by varchar2(20));
    
ALTER TABLE products_price
ADD (created_by varchar2(20), 
    modified_by varchar2(20));
    
ALTER TABLE stores
ADD (created_by varchar2(20), 
    modified_by varchar2(20));

create trigger trg_customers  
BEFORE INSERT OR UPDATE OF created_by, modified_by on customers 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_order_items  
BEFORE INSERT OR UPDATE OF created_by, modified_by on order_items 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_orders  
BEFORE INSERT OR UPDATE OF created_by, modified_by on orders 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_productcolor  
BEFORE INSERT OR UPDATE OF created_by, modified_by on productcolor 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_products 
BEFORE INSERT OR UPDATE OF created_by, modified_by on products 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_products_price  
BEFORE INSERT OR UPDATE OF created_by, modified_by on products_price 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 

create trigger trg_stores  
BEFORE INSERT OR UPDATE OF created_by, modified_by on stores 
FOR EACH ROW 
DECLARE
    myUser varchar2(30);
BEGIN 
    select user into myUser from dual;
  if (inserting) then
        :new.created_by := myUser;
    end if;
    if (updating) then
        :new.modified_by := myUser;
    end if;
END; 



    
    
    
    