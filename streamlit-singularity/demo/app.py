import numpy as np
import pandas as pd
import streamlit as st

st.title("Streamlit on ACTIVATE")
st.write(
    "This demo runs inside a Singularity container behind a pw endpoint. "
    "To serve your own app, set the **App Script** input of the workflow "
    "to the path of your `.py` file on the cluster."
)

points = st.slider("Number of points", 10, 1000, 250)
df = pd.DataFrame(
    np.random.randn(points, 3).cumsum(axis=0), columns=["a", "b", "c"]
)
st.line_chart(df)
st.dataframe(df.describe())
